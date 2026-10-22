#!/usr/bin/env python3
"""Read-only: how much a compaction of one VHDX disk file can give back.

Usage: python3 -I fm-vhdx-bat.py FILE [MB_GROUPS FS_BLOCK_SIZE]

Reads the VHDX header, region table, metadata and block allocation table (BAT)
of FILE without writing anything (about the BAT's size in reads, e.g. 9 MiB
for a 1 TiB disk with 1 MiB blocks) and prints one line:

  reclaimable=B length=B block_size=B fixed=B present=N unmapped=N zero=N not_present=N [trim_more=B]

A compaction (diskpart "compact vdisk", which cannot read the filesystem
inside) drops only payload blocks the BAT marks as not present, undefined,
zero or unmapped, then shrinks the file. So:

  reclaimable = length - block_size * present payload blocks
                - 1 MiB * present sector bitmap blocks - fixed

where fixed is the area compaction keeps whatever the BAT says: the larger of
the file offset of the first present block and the 1 MiB-rounded sum of the
header area, log, and every region (BAT, metadata). present counts
FULLY_PRESENT, PARTIALLY_PRESENT and any state this reader does not know.

With MB_GROUPS (an ext4 /proc/fs/ext4/<dev>/mb_groups file) and the ext4
block size, it also prints trim_more: bytes of payload blocks the BAT holds
present although ext4 has every byte of them free, which a trim would unmap so
the next compaction drops them too. It assumes ext4 fills the whole virtual
disk from offset 0 (as WSL's does) with 8 x FS_BLOCK_SIZE blocks per group;
per group it counts the free buddies that cover whole aligned payload blocks,
less the blocks the BAT already holds absent there, so it is a lower bound.
trim_more is left out when MB_GROUPS cannot be read or does not fit the disk.

Exit 1 with a reason on stderr when FILE cannot be read or is not a VHDX.
"""
import re
import struct
import sys
import uuid

MIB = 1048576
BAT_GUID = uuid.UUID("2DC27766-F623-4200-9D64-115E9BFD4A08")
METADATA_GUID = uuid.UUID("8B7CA206-4790-4B9A-B8FE-575F050F886E")
FILE_PARAMETERS = uuid.UUID("CAA16737-FA36-4D43-B3B6-33F0AA44E76B")
VIRTUAL_DISK_SIZE = uuid.UUID("2FA54224-CD1B-4876-B211-5DBED83BF4B8")
LOGICAL_SECTOR_SIZE = uuid.UUID("8141BF1D-A96F-4709-BA47-F233A8FAAB5F")
# Payload block states that hold no space in the file.
NOT_IN_FILE = {0: "not_present", 1: "not_present", 2: "zero", 3: "unmapped"}
# "#<group> : <free> <frags> <first> [ <free buddies of order 0, 1, ...> ]"
MB_GROUP = re.compile(r"#(\d+)\s*:\s*\d+\s+\d+\s+\d+\s+\[([\d\s]*)\]")


class Bad(Exception):
    pass


def read_at(f, offset, length):
    f.seek(offset)
    data = f.read(length)
    if len(data) != length:
        raise Bad("short read at offset %d" % offset)
    return data


def round_mib(n):
    return (n + MIB - 1) // MIB * MIB


def header(f):
    """The log length from the current header (highest sequence number)."""
    best = None
    for off in (64 * 1024, 128 * 1024):
        h = read_at(f, off, 80)
        if h[:4] != b"head":
            continue
        seq = struct.unpack_from("<Q", h, 8)[0]
        log_length = struct.unpack_from("<I", h, 68)[0]
        if best is None or seq > best[0]:
            best = (seq, log_length)
    if best is None:
        raise Bad("no VHDX header")
    return best[1]


def regions(f):
    for off in (192 * 1024, 256 * 1024):
        r = read_at(f, off, 64 * 1024)
        if r[:4] != b"regi":
            continue
        count = struct.unpack_from("<I", r, 8)[0]
        if count > 2047:
            continue
        out = {}
        for i in range(count):
            e = 16 + 32 * i
            guid = uuid.UUID(bytes_le=r[e:e + 16])
            offset, length = struct.unpack_from("<QI", r, e + 16)
            out[guid] = (offset, length)
        return out
    raise Bad("no region table")


def metadata(f, offset, length):
    m = read_at(f, offset, min(length, 64 * 1024))
    if m[:8] != b"metadata":
        raise Bad("no metadata table")
    count = struct.unpack_from("<H", m, 10)[0]
    items = {}
    for i in range(min(count, 2047)):
        e = 32 + 32 * i
        if e + 32 > len(m):
            break
        guid = uuid.UUID(bytes_le=m[e:e + 16])
        ioff, ilen = struct.unpack_from("<II", m, e + 16)
        if ioff and ilen and ioff + ilen <= length:
            items[guid] = read_at(f, offset + ioff, ilen)
    try:
        block_size = struct.unpack_from("<I", items[FILE_PARAMETERS])[0]
        disk_size = struct.unpack_from("<Q", items[VIRTUAL_DISK_SIZE])[0]
        sector = struct.unpack_from("<I", items[LOGICAL_SECTOR_SIZE])[0]
    except (KeyError, struct.error):
        raise Bad("metadata lacks block size, disk size or sector size")
    if block_size < MIB or block_size > 256 * MIB or block_size & (block_size - 1):
        raise Bad("bad block size %d" % block_size)
    if sector not in (512, 4096) or disk_size <= 0:
        raise Bad("bad disk or sector size")
    return block_size, disk_size, sector


def trim_more(path, fs_block, block_size, states):
    """Bytes of present payload blocks ext4 holds wholly free, or None."""
    group = 8 * fs_block * fs_block
    if fs_block < 2048 or fs_block > block_size or group % block_size:
        return None
    order = block_size.bit_length() - fs_block.bit_length()
    per_group = group // block_size
    total = 0
    seen = False
    with open(path) as f:
        for line in f:
            m = MB_GROUP.match(line)
            if not m:
                continue
            g = int(m.group(1))
            counts = [int(c) for c in m.group(2).split()]
            whole = sum(c << (o - order) for o, c in enumerate(counts) if o >= order)
            span = states[g * per_group:(g + 1) * per_group]
            if not span:
                return None
            absent = sum(1 for s in span if s in NOT_IN_FILE)
            total += max(whole - absent, 0)
            seen = True
    return total * block_size if seen else None


def measure(path, mb_groups=None, fs_block=0):
    with open(path, "rb") as f:
        if read_at(f, 0, 8) != b"vhdxfile":
            raise Bad("not a VHDX file")
        f.seek(0, 2)
        length = f.tell()
        log_length = header(f)
        regs = regions(f)
        if BAT_GUID not in regs or METADATA_GUID not in regs:
            raise Bad("region table lacks the BAT or metadata")
        block_size, disk_size, sector = metadata(f, *regs[METADATA_GUID])
        chunk = (1 << 23) * sector // block_size
        blocks = -(-disk_size // block_size)
        entries = blocks + (blocks - 1) // chunk
        bat_offset, bat_length = regs[BAT_GUID]
        if entries * 8 > bat_length:
            raise Bad("BAT shorter than the disk needs")
        bat = read_at(f, bat_offset, entries * 8)
    counts = {"present": 0, "unmapped": 0, "zero": 0, "not_present": 0}
    bitmaps = 0
    first = None
    states = bytearray()
    for i, (e,) in enumerate(struct.iter_unpack("<Q", bat)):
        state = e & 7
        if (i + 1) % (chunk + 1) == 0:
            if state == 6:
                bitmaps += 1
            else:
                continue
        elif state in NOT_IN_FILE:
            states.append(state)
            counts[NOT_IN_FILE[state]] += 1
            continue
        else:
            states.append(state)
            counts["present"] += 1
        where = (e >> 20) * MIB
        if where and (first is None or where < first):
            first = where
    fixed = MIB + round_mib(log_length) + sum(round_mib(n) for _, n in regs.values())
    if first is not None and first > fixed:
        fixed = first
    reclaimable = length - block_size * counts["present"] - MIB * bitmaps - fixed
    r = dict(
        reclaimable=max(reclaimable, 0), length=length, block_size=block_size, fixed=fixed, **counts
    )
    if mb_groups:
        try:
            more = trim_more(mb_groups, fs_block, block_size, states)
        except (OSError, ValueError):
            more = None
        if more is not None:
            r["trim_more"] = more
    return r


def main(argv):
    if len(argv) not in (2, 4) or (len(argv) == 4 and not argv[3].isdigit()):
        sys.stderr.write("usage: fm-vhdx-bat.py FILE [MB_GROUPS FS_BLOCK_SIZE]\n")
        return 2
    try:
        r = measure(argv[1], *(argv[2], int(argv[3])) if len(argv) == 4 else ())
    except (OSError, Bad) as e:
        sys.stderr.write("fm-vhdx-bat: %s: %s\n" % (argv[1], e))
        return 1
    keys = ("reclaimable", "length", "block_size", "fixed", "present", "unmapped", "zero", "not_present")
    print(" ".join("%s=%d" % (k, r[k]) for k in keys + ("trim_more",) if k in r))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
