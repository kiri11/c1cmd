#!/usr/bin/env python3
"""Offline checks for suite selection, fail-fast behavior, and resource restoration."""
import contextlib
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release_integration_test as runner


class ReleaseRunnerTests(unittest.TestCase):
    def test_selection(self):
        self.assertEqual(tuple(runner.parse_args(['archive']).suites), ('cli', 'mcp', 'existing'))
        self.assertEqual(runner.parse_args(['archive', '--suites', 'all']).suites, list(runner.SUITES))
        self.assertEqual(runner.parse_args(['archive', '--suites', 'lens', 'geometry']).suites, ['lens', 'geometry'])
        self.assertEqual(len(runner.SUITES), 11)
        self.assertFalse(any('recovery' in script for script, _ in runner.SUITES.values()))

    def test_invalid_selection_has_no_side_effects(self):
        for selection in [[], ['unknown'], ['cli', 'cli'], ['all', 'cli']]:
            with self.subTest(selection=selection), patch.object(runner, 'run') as run, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    runner.main(['archive', '--suites', *selection])
                self.assertEqual(error.exception.code, 2)
                run.assert_not_called()

    def test_missing_raw_fails_before_extraction(self):
        with patch.dict(os.environ, C1_TEST_RAW_FIXTURE='/nonexistent/c1-test-raw'), patch.object(runner, 'extract_archive') as extract:
            with self.assertRaises(ValueError):
                runner.run('archive', ['cli'])
            extract.assert_not_called()

    def test_runner_cleanup_and_fail_fast(self):
        for failure in [None, 'package', 'suite', 'timeout']:
            for has_bundle in [False, True]:
                with self.subTest(failure=failure, has_bundle=has_bundle), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory).resolve()
                    raw = root / 'fixture.CR3'
                    raw.write_bytes(b'unchanged RAW')
                    bundle = root / '.build/release/c1_CaptureOneCore.bundle'
                    if has_bundle:
                        bundle.mkdir(parents=True)
                        (bundle / 'resource').write_text('retained resource')
                    original_directory = Path.cwd()
                    calls = []
                    package = None

                    def extract(archive, destination):
                        nonlocal package
                        package = Path(destination) / 'package'
                        package.mkdir()
                        return package

                    def check(extracted):
                        self.assertEqual(extracted, package)
                        self.assertFalse(bundle.exists())
                        self.assertEqual(Path.cwd(), package.parent)
                        calls.append('package')
                        if failure == 'package':
                            raise RuntimeError('bad package')

                    def command(args, **kwargs):
                        self.assertFalse(bundle.exists())
                        self.assertEqual(kwargs['env']['C1_TEST_BIN'], str(package / 'bin/c1'))
                        self.assertEqual(kwargs['env']['C1_TEST_MCP_BIN'], str(package / 'bin/c1-mcp'))
                        self.assertEqual(kwargs['env']['C1_TEST_RAW_FIXTURE'], str(raw))
                        self.assertEqual(kwargs['cwd'], str(package.parent))
                        self.assertTrue(kwargs['check'])
                        self.assertEqual(kwargs['timeout'], 1200 if args[-1].endswith('lens_geometry_integration_test.py') else 600)
                        calls.append(Path(args[-1]).name)
                        if failure == 'suite':
                            raise subprocess.CalledProcessError(1, args)
                        if failure == 'timeout':
                            raise subprocess.TimeoutExpired(args, kwargs['timeout'])

                    output = io.StringIO()
                    with patch.object(runner, 'ROOT', root), patch.dict(os.environ, C1_TEST_RAW_FIXTURE=str(raw)), \
                         patch.object(runner, 'extract_archive', extract), patch.object(runner, 'check_package', check), \
                         patch.object(runner.subprocess, 'run', command), contextlib.redirect_stdout(output):
                        if failure:
                            with self.assertRaises((RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired)):
                                runner.run(root / 'archive', ['lens', 'existing'])
                        else:
                            runner.run(root / 'archive', ['lens', 'existing'])
                    expected = ['package']
                    if failure != 'package':
                        expected.append('lens_geometry_integration_test.py')
                    if not failure:
                        expected.append('existing_variant_integration_test.py')
                    self.assertEqual(calls, expected)
                    self.assertEqual('PASS: selected packaged live suites' in output.getvalue(), failure is None)
                    self.assertIn('Selected live suites: lens, existing', output.getvalue())
                    self.assertIn('Skipped live suites: cli, mcp, geometry', output.getvalue())
                    self.assertEqual(Path.cwd(), original_directory)
                    self.assertEqual(bundle.exists(), has_bundle)
                    if has_bundle:
                        self.assertEqual((bundle / 'resource').read_text(), 'retained resource')
                        self.assertEqual(list(bundle.parent.glob('*.hidden-*')), [])
                    self.assertEqual(raw.read_bytes(), b'unchanged RAW')


if __name__ == '__main__':
    unittest.main()
