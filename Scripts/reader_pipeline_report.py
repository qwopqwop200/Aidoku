#!/usr/bin/env python3
"""Summarize bounded Aidoku reader/performance logs without page text or credentials."""
import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path


def number(row, key, default=0):
    try:
        value = float(row.get(key, default))
        return value if math.isfinite(value) else default
    except (ValueError, TypeError):
        return default


def read_events(paths):
    events = []
    seen = set()
    for path in paths:
        for line in Path(path).read_text(errors='replace').splitlines():
            fields = dict(item.split('=', 1) for item in line.split() if '=' in item)
            event = fields.get('reader_event') or fields.get('pipeline_event')
            if not event or 'time' not in fields:
                continue
            # Reader and performance sinks have independent sequence counters.
            identity = (fields.get('pid'), fields.get('seq'), fields.get('time'), event)
            if identity in seen:
                continue
            seen.add(identity)
            fields['event'] = event
            events.append(fields)
    return sorted(events, key=lambda row: (number(row, 'time'), number(row, 'seq')))


def summarize(events, page=None, token=None):
    # Offscreen work may know only its token until the page becomes visible.
    tokens = {row['page_token'] for row in events if 'page_token' in row and number(row, 'page', -1) == page}
    if token:
        tokens = {token.lower().removeprefix('0x')}
    if page is not None or token:
        events = [row for row in events if row.get('page_token') in tokens or
                  (not token and number(row, 'page', -1) == page)]
    phases = defaultdict(list)
    milestones = Counter()
    pending = Counter()
    problems = []
    for row in events:
        event = row['event']
        milestones[event] += 1
        duration = number(row, 'elapsed_ms', -1)
        if duration < 0 and event == 'transport':
            duration = number(row, 'total_ms', -1)
        if duration >= 0:
            phases[event].append(duration)
        trace = (row.get('pid', '?'), row.get('trace', '?'))
        if row.get('trace') and event.endswith('_begin'):
            pending[trace + (event[:-6],)] += 1
        elif row.get('trace') and event.endswith('_end'):
            key = trace + (event[:-4],)
            if pending[key] > 0:
                pending[key] -= 1
        if (number(row, 'outcome') != 0 or any(word in event for word in
                ('failed', 'failure', 'fallback', 'wrong_language', 'mismatch', 'before_layout', 'cancelled'))):
            problems.append({key: row[key] for key in ('time', 'event', 'page', 'page_token', 'trace', 'code', 'outcome') if key in row})
    timings = []
    for event, values in phases.items():
        values.sort()
        timings.append(dict(event=event, count=len(values), mean_ms=sum(values)/len(values),
                            p95_ms=values[max(0, math.ceil(len(values)*.95)-1)], max_ms=values[-1]))
    return {
        'events': len(events), 'page': page, 'page_tokens': sorted(tokens),
        'dropped': sum(int(number(row, 'dropped')) for row in events),
        # This cumulative counter is per sink/process; report its maximum, not a sum.
        'max_writer_failures': max((int(number(row, 'write_failures')) for row in events), default=0),
        'phases': sorted(timings, key=lambda phase: phase['max_ms'], reverse=True),
        'milestones': dict(milestones), 'problems': problems,
        'unmatched_starts': [dict(pid=pid, trace=trace, stage=stage, count=count)
                             for (pid, trace, stage), count in pending.items() if count],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('logs', nargs='+', type=Path)
    parser.add_argument('--page', type=int, help='1-based chapter page; resolves offscreen events via page_token')
    parser.add_argument('--token', help='Filter a page token, useful when several chapters contain the same page number')
    parser.add_argument('--json', action='store_true', help='Emit machine-readable data')
    args = parser.parse_args()
    try:
        report = summarize(read_events(args.logs), args.page, args.token)
    except OSError as error:
        parser.error(str(error))
    if args.json:
        print(json.dumps(report, indent=2))
        return
    print(f"Events: {report['events']} | dropped: {report['dropped']} | writer failures (max): {report['max_writer_failures']}")
    print('Durations include nested work/waits; do not add them together.')
    print(f"{'Stage':38} {'Count':>6} {'Mean ms':>11} {'P95 ms':>11} {'Max ms':>11}")
    for phase in report['phases']:
        print(f"{phase['event']:38} {phase['count']:6} {phase['mean_ms']:11.2f} {phase['p95_ms']:11.2f} {phase['max_ms']:11.2f}")
    print('\nCache and display milestones:')
    for event, count in sorted(report['milestones'].items()):
        if any(word in event for word in ('hit', 'miss', 'joined', 'adopt', 'attached', 'committed', 'wait', 'queued', 'admitted')):
            print(f'  {event}: {count}')
    print('\nFailures/cancellations/fallbacks (latest 30):')
    for row in report['problems'][-30:]:
        print('  ' + ' '.join(f'{key}={value}' for key, value in row.items()))
    if report['unmatched_starts']:
        print('\nUnmatched starts (may reflect cancellation, rotation, dropped events or an active stage):')
        for row in report['unmatched_starts'][-20:]:
            print('  ' + ' '.join(f'{key}={value}' for key, value in row.items()))


if __name__ == '__main__':
    main()
