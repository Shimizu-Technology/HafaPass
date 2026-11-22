import json
from pathlib import Path
import unittest
from ci_change_scope import docs_only
from ci_rspec import partition, verify_coverage


class CiHelpersTest(unittest.TestCase):
    def test_documentation_filter_is_conservative(self):
        self.assertTrue(docs_only(['README.md', 'docs/qa/evidence.md']))
        for paths in ([], ['docs/fixture.json'], ['hafapass_api/README.md'],
                      ['README.md', '.github/workflows/ci.yml'], ['docs/README.md', 'scripts/tool.py']):
            self.assertFalse(docs_only(paths))

    def test_timing_balancing_and_new_files_have_exact_coverage(self):
        groups, totals = partition(['slow', 'medium', 'short', 'new'],
                                   {'slow': 10, 'medium': 7, 'short': 3})
        self.assertEqual(sorted(sum(groups, [])), ['medium', 'new', 'short', 'slow'])
        self.assertEqual(sorted(totals), [10, 12])

    def test_current_suite_partition_is_balanced(self):
        root = Path(__file__).resolve().parents[1]
        files = [str(p.relative_to(root / 'hafapass_api'))
                 for p in (root / 'hafapass_api/spec').rglob('*_spec.rb')]
        groups, totals = partition(files, json.loads((root / 'scripts/ci_rspec_timings.json').read_text()))
        self.assertEqual(len(sum(groups, [])), len(set(files)))
        self.assertLess(abs(totals[0] - totals[1]), 3)

    def test_identity_check_rejects_same_count_with_duplicate_or_missing(self):
        verify_coverage(['a', 'b'], ['b', 'a'])
        for expected, actual in [(['a', 'b'], ['a', 'a']), (['a'], ['a', 'b']),
                                 (['a', 'b'], ['a']), (['a', 'a'], ['a'])]:
            with self.assertRaises(RuntimeError):
                verify_coverage(expected, actual)

class ChangeScopeEntrypointTest(unittest.TestCase):
    def test_git_boundaries_and_exact_output(self):
        import os
        import subprocess
        import sys
        import tempfile
        script = Path(__file__).resolve().with_name('ci_change_scope.py')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, text=True).strip()

            git('init', '-q')
            git('config', 'user.name', 'CI test')
            git('config', 'user.email', 'ci@example.test')
            (root / 'code.py').write_text('example')
            git('add', '.')
            git('commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')

            def assert_output(base_sha, expected):
                output = root / 'github-output'
                output.write_text('existing=value\n')
                subprocess.run([sys.executable, str(script)], cwd=root, check=True,
                               env=dict(os.environ, BASE_SHA=base_sha, GITHUB_OUTPUT=str(output)))
                self.assertEqual(output.read_text(), 'existing=value\ncode=' + expected + '\n')

            for unavailable in ('', '0' * 40, 'f' * 40):
                assert_output(unavailable, 'true')
            # --no-renames must include the deleted code path, even with identical content.
            git('mv', 'code.py', 'README.md')
            git('commit', '-qm', 'rename code to Markdown')
            assert_output(base, 'true')
            docs_base = git('rev-parse', 'HEAD')
            (root / 'README.md').write_text('documentation update')
            git('add', 'README.md')
            git('commit', '-qm', 'docs only')
            assert_output(docs_base, 'false')
            assert_output(git('rev-parse', 'HEAD'), 'true')


class RunnerIntegrationTest(unittest.TestCase):
    def test_runner_isolates_databases_and_propagates_test_failure(self):
        import os
        import subprocess
        import sys
        import tempfile
        import textwrap
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            api = root / 'api'
            (api / 'spec').mkdir(parents=True)
            (root / 'scripts').mkdir()
            (root / 'scripts/ci_rspec_timings.json').write_text('{}')
            for name in ('a', 'b'):
                (api / f'spec/{name}_spec.rb').touch()
            bundle = root / 'bundle'
            bundle.write_text(textwrap.dedent('''\
                #!/usr/bin/env python3
                import json, os, pathlib, sys
                args = sys.argv[1:]
                with open('../commands.jsonl', 'a') as log:
                    log.write(json.dumps([args, os.environ['DATABASE_URL']]) + '\\n')
                if 'rspec' in args:
                    files = ['spec/a_spec.rb', 'spec/b_spec.rb'] if '--dry-run' in args else [a for a in args if a.endswith('_spec.rb')]
                    report = {'examples': [{'id': './' + f + '[1:1]'} for f in files]}
                    pathlib.Path(args[args.index('--out') + 1]).write_text(json.dumps(report))
                    if '--dry-run' not in args and os.environ.get('FAIL_WORKER') == '1':
                        sys.exit(1)
                '''))
            bundle.chmod(0o755)
            script = Path(__file__).resolve().with_name('ci_rspec.py')
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}', RAILS_ENV='test',
                       DATABASE_URL='postgresql://localhost/ci_test')
            for fail in ('0', '1'):
                result = subprocess.run([sys.executable, str(script)], cwd=api,
                                        env=dict(env, FAIL_WORKER=fail), capture_output=True, text=True)
                self.assertEqual(result.returncode, int(fail), result.stderr)
                self.assertIn('2 examples, each executed exactly once', result.stdout)
            commands = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()]
            self.assertEqual({url for _, url in commands},
                             {'postgresql://localhost/ci_w1_test', 'postgresql://localhost/ci_w2_test'})


if __name__ == '__main__':
    unittest.main()
