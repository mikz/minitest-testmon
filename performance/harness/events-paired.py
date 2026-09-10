#!/usr/bin/env python3
"""Paired cold-suite benchmark, confined to an ephemeral CI checkout."""
import json
import os
from pathlib import Path
import re
import resource
import signal
import sqlite3
import subprocess
import sys
import time

order = sys.argv[1]
assert order in ('off-on', 'on-off')
output = Path('tmp/testmon-performance')
output.mkdir(parents=True, exist_ok=False)
cache = (output / 'cold.sqlite3').resolve()
base_env = os.environ.copy()
base_env.pop('RUBYOPT', None)
base_env.pop('MINITEST_TESTMON_FULL', None)
base_env.update(RAILS_ENV='test', PARALLEL_WORKERS='2', MINITEST_TESTMON_DB=str(cache))
rows = []


def measure(mode):
    enabled = mode != 'off'
    environment = dict(base_env, MINITEST_TESTMON='1' if enabled else '0')
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.monotonic()
    with (output / (mode + '.log')).open('w') as log:
        process = subprocess.Popen(['bin/rails', 'test:all', '--seed', '3675'],
                                   env=environment, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            status = process.wait(timeout=60 if mode == 'warm' else 420)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            status = 124
    elapsed = time.monotonic() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    text = (output / (mode + '.log')).read_text()
    counts = re.findall(r'(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips', text)
    row = dict(mode=mode, wall_seconds=elapsed, exit=status,
               child_user_seconds=after.ru_utime-before.ru_utime,
               child_system_seconds=after.ru_stime-before.ru_stime,
               counts=[int(value) for value in counts[-1]] if counts else None)
    if enabled and cache.exists():
        with sqlite3.connect('file:' + str(cache) + '?mode=ro', uri=True) as database:
            receipt = database.execute('select report_json from run_receipts order by started_at desc limit 1').fetchone()
            report = json.loads(receipt[0]) if receipt and receipt[0] else {}
            row['publication'] = report.get('publication')
            row['diagnostics'] = report.get('diagnostics')
            row['snapshots'] = database.execute('select count(*) from test_snapshots').fetchone()[0]
            row['retries'] = database.execute('select count(*) from retry_tests').fetchone()[0]
            row['selected'] = len(report.get('tests', {}).get('selected', [])) if report else None
    rows.append(row)
    (output / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
    print(json.dumps(row), flush=True)
    assert status == 0, 'Suite failed or exceeded its bounded deadline; inspect artifact logs'
    assert row['counts'] == ([0, 0, 0, 0, 0] if mode == 'warm' else [872, 9944, 0, 0, 0]), row
    if enabled:
        assert row['publication']['published'] and row['retries'] == 0 and row['snapshots'] == 872, row
        assert row['diagnostics'] == [], row
    if mode == 'warm':
        assert row['selected'] == 0, row


for mode in order.split('-'):
    measure(mode)
measure('warm')
by_mode = {row['mode']: row for row in rows}
ratio = by_mode['on']['wall_seconds'] / by_mode['off']['wall_seconds'] - 1
summary = f"Testmon cold overhead ({order}): {ratio:.1%}; cold and warm publication verified.\n"
print(summary, flush=True)
Path(os.environ['GITHUB_STEP_SUMMARY']).write_text(summary)
# Keep a failed gate visible; never interpret a benchmark above the limit as success.
assert ratio <= 0.30, summary
