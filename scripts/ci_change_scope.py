#!/usr/bin/env python3
"""Skip heavy jobs only for Markdown documentation; uncertainty runs everything."""
import os
from pathlib import PurePosixPath
import subprocess


def docs_only(paths):
    return bool(paths) and all(
        path.endswith('.md') and (len(PurePosixPath(path).parts) == 1 or path.startswith('docs/'))
        for path in paths
    )


def main():
    base = os.environ.get('BASE_SHA', '')
    code = True
    if base and set(base) != {'0'} and subprocess.run(
        ['git', 'cat-file', '-e', f'{base}^{{commit}}'], capture_output=True
    ).returncode == 0:
        diff = subprocess.run(['git', 'diff', '--name-only', '--no-renames', '-z', base, 'HEAD'],
                              capture_output=True, check=True)
        paths = diff.stdout.decode().rstrip('\0').split('\0') if diff.stdout else []
        code = not docs_only(paths)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'code={str(code).lower()}\n')


if __name__ == '__main__':
    main()
