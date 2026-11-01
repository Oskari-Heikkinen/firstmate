"""Owner-only runner source recovery, behind the engine's watcher-lock check.

No public CLI. read() also serves read-only alarm diagnosis. The bounded
.runner-recovery/v1 record is owned by docs/owner-notice.md. Mutations use the
existing durable publisher; neither health/grace nor a count grants recovery.
"""
import os
import re
import time

import fm_owner_notice_format as fmt
from fm_owner_notice_runtime import fields, attempt_record, runner_start_status, publish, TOKEN

SCHEMA = 'fm-owner-notice-runner-recovery/v1'
SOURCES = ('configuration', 'reservation', 'counter-read', 'counter-write', 'failed-start')
BOUND = 8192
MAX_EPOCH = 253402300799


def epoch(value):
    return type(value) is int and 0 <= value <= MAX_EPOCH


def identity(value):
    return (isinstance(value, dict) and set(value) == {'attempt', 'pid', 'starttime'}
            and isinstance(value['attempt'], str) and TOKEN.fullmatch(value['attempt'])
            and isinstance(value['pid'], str) and re.fullmatch(r'[0-9]{1,10}', value['pid'])
            and 1 < int(value['pid']) < 2**31
            and isinstance(value['starttime'], str) and re.fullmatch(r'[0-9]{1,20}', value['starttime']))


def snapshot_valid(value, allow_absent=False):
    return (isinstance(value, dict) and set(value) == {'attempt', 'baseline', 'identity'}
            and ((allow_absent and value['attempt'] is None)
                 or (isinstance(value['attempt'], str) and TOKEN.fullmatch(value['attempt'])))
            and (value['baseline'] is None or fmt.valid_sha(value['baseline']))
            and (value['identity'] is None
                 or (identity(value['identity']) and value['identity']['attempt'] == value['attempt'])))


def read(owner):
    path = os.path.join(owner.root, '.runner-recovery')
    try:
        obj = fmt.parse_canonical(fmt.read_regular_nofollow(path, BOUND, 'runner-recovery'))
    except FileNotFoundError:
        if os.path.lexists(path):
            raise fmt.FormatError('dangling runner recovery record') from None
        return None
    if (not isinstance(obj, dict) or set(obj) != {'schema', 'phase', 'sources', 'candidate'}
            or obj['schema'] != SCHEMA or obj['phase'] not in ('pending', 'ready', 'cleared')
            or not isinstance(obj['sources'], dict) or not obj['sources']
            or any(k not in SOURCES for k in obj['sources'])):
        raise fmt.FormatError('invalid runner recovery record')
    for row in obj['sources'].values():
        if (not isinstance(row, dict) or set(row) != {'since', 'reason', 'repaired', 'observed'}
                or not epoch(row['since']) or type(row['repaired']) is not bool
                or not isinstance(row['reason'], str) or not 0 < len(row['reason']) <= 512
                or any(c in row['reason'] for c in '\n\r\x00')
                or (row['observed'] != 'unknown' and not snapshot_valid(row['observed'], allow_absent=True))):
            raise fmt.FormatError('invalid runner recovery source')
    candidate = obj['candidate']
    if candidate is not None:
        if (not snapshot_valid(candidate) or not all(r['repaired'] for r in obj['sources'].values())):
            raise fmt.FormatError('invalid runner recovery candidate')
    if obj['phase'] in ('ready', 'cleared') and (candidate is None or not all(r['repaired'] for r in obj['sources'].values())):
        raise fmt.FormatError('runner recovery completion without proof')
    return obj


def save(owner, obj):
    data = fmt.canonical(obj)
    if len(data) > BOUND:
        raise fmt.FormatError('runner recovery record exceeds bound')
    publish(owner, os.path.join(owner.root, '.runner-recovery'), data.decode('ascii'), 'o-recovery-dirsync')


def observation(owner):
    """Return current reserved token, validated beat digest, matching identity.

    A previous beat is a valid baseline, not current progress. Capturing its
    exact validated fields after source repair establishes order without comparing wall
    clocks. A beat from a different attempt cannot satisfy that candidate.
    """
    attempt = attempt_record(owner.root)
    beat = fields(os.path.join(owner.root, '.runner-beat'))
    installed = fields(os.path.join(owner.root, '.runner'))
    runner_start_status(owner.root, beat)  # Shared history validation, never its grace verdict.
    digest, matched = None, None
    if beat is not None:
        ident = {k: beat.get(k) for k in ('attempt', 'pid', 'starttime')}
        if (set(beat) not in ({'attempt', 'pid', 'starttime', 'epoch'}, {'attempt', 'pid', 'starttime', 'epoch', 'drained'})
                or not identity(ident) or not str(beat.get('epoch', '')).isdigit()
                or not epoch(int(beat['epoch'])) or beat.get('drained', 'yes') != 'yes'):
            raise fmt.FormatError('invalid recovery progress beat')
        digest = fmt.sha256_hex(fmt.canonical(beat))
        if (attempt and installed and ident['attempt'] == attempt['token']
                and all(installed.get(k) == v for k, v in ident.items())):
            matched = ident
    return attempt['token'] if attempt else None, digest, matched


def refusal_observation(owner):
    try:
        token, digest, matched = observation(owner)
        return {'attempt': token, 'baseline': digest, 'identity': matched}
    except (OSError, fmt.FormatError):
        # A broken source can also make its observation unreadable. Preserve
        # that uncertainty with the failure, never invent an empty baseline.
        return 'unknown'


def pending_action(owner):
    # Queue format/validation stays with its one owner. No publisher lease or
    # writer transaction: this is a bounded read-only last-request observation.
    from fm_owner_notice_alarm import pending_action as action
    return action(owner, 'runner-respawn-failing')


def status(owner, held):
    obj = read(owner)
    action = pending_action(owner)
    # A clear already accepted into the FIFO still owns its completion. Do
    # not reinterpret its not-yet-cleared native level as another failure.
    if (obj is None or obj['phase'] == 'cleared') and (action == 'assert' or (held and action != 'clear')):
        obj = {'schema': SCHEMA, 'phase': 'pending', 'candidate': None,
               'sources': {s: {'since': int(time.time()), 'reason': 'unattributed held failure; revalidate source',
                               'repaired': False, 'observed': refusal_observation(owner)} for s in SOURCES}}
        save(owner, obj)
    return obj


def fail(owner, source, reason):
    if source not in SOURCES or not reason or len(reason) > 512 or any(c in reason for c in '\n\r\x00'):
        raise fmt.FormatError('invalid runner recovery failure')
    obj = read(owner)
    if obj is None or obj['phase'] == 'cleared':
        obj = {'schema': SCHEMA, 'phase': 'pending', 'sources': {}, 'candidate': None}
    old = obj['sources'].get(source)
    obj['sources'][source] = {'since': old['since'] if old else int(time.time()), 'reason': reason,
                              'repaired': False, 'observed': refusal_observation(owner)}
    obj['candidate'] = None
    obj['phase'] = 'pending'
    save(owner, obj)


def repair(owner, source):
    if source not in SOURCES:
        raise fmt.FormatError('invalid runner recovery source')
    obj = read(owner)
    if obj is None or obj['phase'] != 'pending':
        return
    if source not in obj['sources'] and source != 'reservation':
        return
    changed = source in obj['sources'] and not obj['sources'][source]['repaired']
    if source in obj['sources']:
        obj['sources'][source]['repaired'] = True
    if all(r['repaired'] for r in obj['sources'].values()):
        token, digest, matched = observation(owner)
        # No reserved attempt means there can be no matching progress yet.
        # A later successful reservation establishes the first candidate.
        if token and (obj['candidate'] is None or obj['candidate']['attempt'] != token):
            obj['candidate'] = {'attempt': token, 'baseline': digest, 'identity': matched}
            obj['phase'] = 'pending'
            changed = True
    if changed:
        save(owner, obj)


def advance(owner):
    obj = read(owner)
    if obj is None or obj['phase'] != 'pending' or obj['candidate'] is None:
        return obj
    token, digest, matched = observation(owner)
    c = obj['candidate']
    if (matched and token == c['attempt'] and digest != c['baseline']
            and (c['identity'] is None or matched == c['identity'])):
        obj['phase'] = 'ready'
        save(owner, obj)
    return obj


def cleared(owner):
    obj = read(owner)
    if obj is None or obj['phase'] != 'ready':
        raise fmt.FormatError('runner recovery clear without ready proof')
    # The engine checks that the exact clear is accepted by the FIFO before
    # this acknowledgement. Retain the proof for idempotent replacement reads.
    if pending_action(owner) != 'clear':
        raise fmt.FormatError('runner recovery clear not queued')
    obj['phase'] = 'cleared'
    save(owner, obj)


def describe(obj):
    if obj is None or obj['phase'] == 'cleared':
        return 'clear -'
    needed = ','.join(s for s in SOURCES if s in obj['sources'] and not obj['sources'][s]['repaired'])
    return obj['phase'] + ' ' + (needed or '-')
