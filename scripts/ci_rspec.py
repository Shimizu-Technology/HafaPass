#!/usr/bin/env python3
"""Two timing-balanced RSpec processes, isolated databases, exact example coverage."""
import collections
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
from urllib.parse import urlsplit, urlunsplit


def partition(files, timings):
    groups, totals = [[], []], [0.0, 0.0]
    # New files still run, with a conservative estimate until timings are refreshed.
    for file in sorted(files, key=lambda f: (-timings.get(f, 2.0), f)):
        index = min(range(2), key=lambda i: (totals[i], i))
        groups[index].append(file)
        totals[index] += timings.get(file, 2.0)
    assert sorted(sum(groups, [])) == sorted(files)
    assert all(groups), 'Expected at least two spec files'
    return groups, totals


def verify_coverage(expected, actual):
    counts = collections.Counter(actual)
    missing = set(expected) - counts.keys()
    extra = counts.keys() - set(expected)
    duplicates = [key for key, count in counts.items() if count != 1]
    if missing or extra or duplicates or len(expected) != len(set(expected)):
        raise RuntimeError(f'RSpec coverage mismatch: missing={sorted(missing)}, '
                           f'extra={sorted(extra)}, duplicates={duplicates}')
    print(f'Coverage verified: {len(expected)} examples, each executed exactly once', flush=True)


def example_ids(path):
    result = json.loads(path.read_text())
    if result.get('summary', {}).get('errors_outside_of_examples_count', 0):
        raise RuntimeError(f'RSpec load errors in {path}')
    return [example['id'] for example in result['examples']]


def main():
    if os.environ.get('RAILS_ENV') != 'test':
        raise RuntimeError('RAILS_ENV must be test')
    url = urlsplit(os.environ['DATABASE_URL'])
    if url.hostname not in ('localhost', '127.0.0.1') or not url.path.endswith('_test'):
        raise RuntimeError('Only a localhost test database is allowed')
    output = Path('tmp/ci-rspec')
    output.mkdir(parents=True, exist_ok=True)
    timings = json.loads(Path('../scripts/ci_rspec_timings.json').read_text())
    groups, totals = partition(list(map(str, Path('spec').rglob('*_spec.rb'))), timings)
    environments = []
    for index in range(2):
        worker_url = urlunsplit(url._replace(path=f'{url.path}_worker{index + 1}'))
        env = dict(os.environ, DATABASE_URL=worker_url)
        subprocess.run(['bundle', 'exec', 'rails', 'db:create', 'db:schema:load'], env=env, check=True)
        environments.append(env)
    manifest = {'groups': groups, 'estimated_seconds': totals}
    (output / 'partition.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Timing-balanced worker estimates: {totals}', flush=True)
    expected_path = output / 'discovery.json'
    subprocess.run(['bundle', 'exec', 'rspec', '--dry-run', '--format', 'json',
                    '--out', str(expected_path)], env=environments[0], check=True)

    def run_worker(index):
        return subprocess.run([
            'bundle', 'exec', 'rspec', *groups[index], '--format', 'progress',
            '--format', 'json', '--out', str(output / f'worker{index + 1}.json'),
            '--format', 'RspecJunitFormatter', '--out', f'tmp/rspec-{index + 1}.xml',
        ], env=environments[index]).returncode

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        statuses = list(pool.map(run_worker, range(2)))
    actual = sum((example_ids(output / f'worker{i + 1}.json') for i in range(2)), [])
    verify_coverage(example_ids(expected_path), actual)
    if any(statuses):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
