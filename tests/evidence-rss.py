#!/usr/bin/env python3
"""Run an isolated fixture command and assert sampled aggregate Linux tree RSS.

Usage: evidence-rss.py <peak-output> <limit-KiB> <command> [args...]
The caller owns fixture isolation and cleanup. Samples end on process exit;
there is no time-based success condition. A peak breach is sticky, and the
fixture is allowed to finish so its output still proves preservation behavior.
"""
import os
import subprocess
import sys
import time


def tree_rss(root):
    total = 0
    pending = [root]
    seen = set()
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        try:
            with open(f'/proc/{pid}/status', encoding='ascii') as status:
                for line in status:
                    if line.startswith('VmRSS:'):
                        total += int(line.split()[1])
            with open(f'/proc/{pid}/task/{pid}/children', encoding='ascii') as children:
                pending.extend(map(int, children.read().split()))
        except FileNotFoundError:
            # Processes can exit between the status and children reads.
            continue
    return total


output, limit, *command = sys.argv[1:]
if not os.path.isdir('/proc/self/task'):
    raise SystemExit('Linux procfs is required for the RSS regression')
child = subprocess.Popen(command)
peak = 0
while True:
    peak = max(peak, tree_rss(child.pid))
    rc = child.poll()
    if rc is not None:
        break
    time.sleep(0.01)
with open(output, 'w', encoding='ascii') as receipt:
    receipt.write(f'peak_tree_rss_kib={peak}\nlimit_kib={limit}\ncommand_exit={rc}\n')
if not peak or peak > int(limit):
    raise SystemExit(f'process tree peak RSS {peak} KiB exceeds bound {limit} KiB (or no sample)')
raise SystemExit(rc)
