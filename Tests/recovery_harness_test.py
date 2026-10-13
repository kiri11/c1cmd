#!/usr/bin/env python3
"""Offline recovery-harness safeguards; never contacts Capture One."""
import json
import contextlib
import io
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import recovery_integration_test as harness


class HarnessTests(unittest.TestCase):
    def test_case_selection_rejects_invalid_before_setup(self):
        people = self.root / 'people.CR3'
        people.write_bytes(b'offline people RAW')
        with patch.dict(os.environ, C1_TEST_PEOPLE_FIXTURE=str(people)):
            self.assertEqual(harness.parse_args(['archive', 'evidence']).cases,
                             (['barrier'], list(harness.RECOVERY_CASES), list(harness.RECIPE_CASES)))
            self.assertEqual(harness.parse_args(['archive', 'evidence', '--cases', 'tonal', 'barrier']).cases,
                             (['barrier'], ['tonal'], []))
        self.assertEqual(len(harness.ALL_CASES), 27)
        self.assertEqual(harness.selected_cases(['preview', 'clone-readback']), ['clone-readback', 'preview'])
        self.assertEqual(harness.parse_args(['archive', 'evidence', '--cases', 'recipe:lens', 'tonal', 'recipe:native']).cases,
                         ([], ['tonal'], ['native', 'lens']))
        self.assertEqual(harness.parse_args(['archive', 'evidence', '--cases', 'recipe:layer-color']).cases, ([], [], ['layer-color']))
        invalid = [[], ['unknown'], ['preview', 'preview'], ['all', 'preview'], ['layer-color'], ['recipe:clone-readback'],
                   ['recipe:lens', 'recipe:lens'], ['recipe:all'], ['recipe:barrier']]
        environment = {key: value for key, value in os.environ.items() if key != 'C1_TEST_PEOPLE_FIXTURE'}
        for cases, people_fixture in [*((cases, str(people)) for cases in invalid), (['barrier'], None),
                                      (['all'], str(self.root / 'missing.CR3'))]:
            with self.subTest(cases=cases, people=people_fixture), patch.object(harness, 'Run') as run, \
                 patch.dict(os.environ, environment, clear=True), contextlib.redirect_stderr(io.StringIO()):
                if people_fixture:
                    os.environ['C1_TEST_PEOPLE_FIXTURE'] = people_fixture
                with self.assertRaises(SystemExit) as error:
                    harness.main(['archive', 'evidence', '--cases', *cases])
                self.assertEqual(error.exception.code, 2)
                run.assert_not_called()

    def test_campaign_runs_groups_in_order_and_stops_on_failure(self):
        import barrier_integration_test as barriers
        import recipe_recovery_integration_test as recipes
        people = self.root / 'people.CR3'
        people.write_bytes(b'offline people RAW')
        environment = patch.dict(os.environ, C1_TEST_PEOPLE_FIXTURE=str(people))
        environment.start()
        self.addCleanup(environment.stop)
        for failure in [None, 'barrier', 'recovery']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                calls = []
                def group(name):
                    def create(*arguments):
                        evidence = arguments[-1]
                        def run_cases(cases):
                            calls.append((name, evidence.name, cases))
                            if failure == name:
                                raise RuntimeError(name)
                        run = Mock()
                        run.run.side_effect = run_cases
                        run.finish.side_effect = lambda: calls.append((name, 'finish'))
                        return run
                    return create
                evidence = Path(directory) / 'evidence'
                with patch.object(harness, 'Run', group('recovery')), patch.object(recipes, 'RecipeRun', group('recipes')), \
                     patch.object(barriers, 'BarrierRun', group('barrier')), contextlib.redirect_stdout(io.StringIO()) as output:
                    arguments = ['archive', str(evidence), '--cases', 'recipe:geometry', 'preview', 'barrier']
                    if failure:
                        with self.assertRaises(RuntimeError):
                            harness.main(arguments)
                    else:
                        harness.main(arguments)
                expected = [('barrier', 'barrier', ['barrier']), ('barrier', 'finish')]
                if failure != 'barrier':
                    expected += [('recovery', 'recovery', ['preview']), ('recovery', 'finish')]
                if not failure:
                    expected += [('recipes', 'recipe-recovery', ['geometry']), ('recipes', 'finish')]
                self.assertEqual(calls, expected)
                self.assertIn('Selected recovery cases: barrier, preview, recipe:geometry', output.getvalue())
                self.assertIn('recipe:lens', output.getvalue().split('Skipped recovery cases: ')[1])
                self.assertEqual('PASS' in output.getvalue(), failure is None)
                with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                    harness.parse_args(['archive', str(evidence), '--cases', 'unknown'])
                # An existing evidence directory is never reused.
                with self.assertRaises(FileExistsError), contextlib.redirect_stdout(io.StringIO()):
                    harness.main(['archive', str(evidence), '--cases', 'preview'])

    def test_selected_faults_skip_unrelated_stress_and_timeouts(self):
        self.run.fault = Mock()
        self.run.preview_timeout = Mock()
        self.run.mcp_death = Mock()
        self.run.clone = Mock()
        self.run.run_cases(['preview', 'mcp-death'])
        self.run.preview_timeout.assert_called_once_with()
        self.run.mcp_death.assert_called_once_with()
        self.run.fault.assert_not_called()
        self.run.clone.assert_not_called()

    def test_case_failure_stops_without_dispatching_next_fault(self):
        self.run.fault = Mock(side_effect=TimeoutError('recovery failed'))
        self.run.preview_timeout = Mock()
        with self.assertRaises(TimeoutError):
            self.run.run_cases(['lens', 'preview'])
        self.run.fault.assert_called_once_with(harness.FAULTS['lens'][0])
        self.run.preview_timeout.assert_not_called()

    def test_full_case_dispatch_and_fault_mechanisms(self):
        calls = []
        self.run.clone = Mock(return_value=({'workingRef': 'clone', 'cloneVariantId': '2'}, {}))
        self.run.cli = Mock(return_value=[{'id': '1'}])
        self.run.source = '1'
        self.run.lookup_identities = Mock(return_value=[
            {'variantId': '2', 'isPresent': False, 'parentImagePath': ''},
            {'variantId': '1', 'isPresent': True, 'parentImagePath': str(self.run.raw)}])
        self.run.fault = lambda fault: calls.append((fault.label, fault.interruption, fault.resolution))
        self.run.preview_timeout = lambda: calls.append(('preview', 'timeout', 'restart'))
        self.run.late_preview = lambda: calls.append(('late-preview', 'timeout', 'late-preview'))
        self.run.save_stall = lambda: calls.append(('save-stall', 'stall', 'restart'))
        self.run.mcp_death = lambda: calls.append(('mcp-death', 'kill', 'restart'))
        self.run.run_cases(['all'])
        self.assertEqual(self.run.clone.call_count, 10)
        self.run.lookup_identities.assert_called_once_with(['2', '1'])
        barrier = [(label, 'kill', 'barrier') for label in (
            'native-property', 'native-action', 'geometry', 'rotation-only-geometry', 'orientation-geometry',
            'orientation-only-geometry', 'corrected-geometry',
            'perspective-geometry', 'keystone-geometry', 'clone', 'delete')]
        self.assertEqual(calls, [('tonal', 'kill', 'barrier'), ('tonal-apple-event-timeout', 'timeout', 'restart'),
                                 ('metadata', 'kill', 'barrier'), *barrier,
                                 ('preview', 'timeout', 'restart'), ('late-preview', 'timeout', 'late-preview'),
                                 ('save-stall', 'stall', 'restart'), ('mcp-death', 'kill', 'restart')])

    def test_barrier_coverage_follows_operation_and_action(self):
        covered = [{'operationType': kind} for kind in ('set', 'add', 'reset', 'metadata_set', 'geometry_set',
                                                       'geometry_restore', 'clone', 'baseline', 'delete')]
        covered += [{'operationType': 'native', 'nativePatch': {'clarity amount': 5}},
                    {'operationType': 'native', 'nativeAction': 'layer.create'},
                    {'operationType': 'native', 'nativeAction': 'mask.people'},
                    {'operationType': 'native', 'nativeAction': 'mask.fill'}]
        uncovered = [{'operationType': 'preview'}, {'operationType': 'lens-fixture'},
                     {'operationType': 'set', 'saveStalledAt': '2026-10-13T00:00:00Z'}]
        uncovered += [{'operationType': 'native', 'nativeAction': action} for action in (
            'mask.feather', 'mask.refine')]
        for entry in covered:
            self.assertTrue(harness.barrier_covered(entry), entry)
        for entry in uncovered:
            self.assertFalse(harness.barrier_covered(entry), entry)

    def interrupt_patches(self, reply='', status='pending', code=-signal.SIGKILL):
        pending = {'operationId': 'operation', 'status': 'pending'}
        self.run.pid = Mock(return_value=100)
        self.run.records = Mock(side_effect=[[], [pending], [pending, dict(pending, status=status)]])
        child = Mock(returncode=None)
        child.poll.return_value = code
        def communicate(timeout):
            child.returncode = code
            return reply, ''
        child.communicate.side_effect = communicate
        watchdog = Mock()
        for target, name, value in [(harness, 'wait_for', lambda predicate, seconds: predicate()), (harness.os, 'kill', Mock()),
                                    (harness.subprocess, 'Popen', Mock(side_effect=[child, watchdog]))]:
            p = patch.object(target, name, value)
            p.start()
            self.addCleanup(p.stop)
        return child, watchdog

    def test_kill_interruption_leaves_write_pending_and_resumes(self):
        child, watchdog = self.interrupt_patches()
        pending, reply = self.run.interrupt(['c1', 'set'], harness.KILL)
        self.assertEqual((pending['operationId'], reply), ('operation', None))
        child.kill.assert_called_once_with()
        self.assertEqual(harness.os.kill.call_args_list, [unittest.mock.call(100, signal.SIGSTOP), unittest.mock.call(100, signal.SIGCONT)])
        watchdog.terminate.assert_called_once_with()
        self.assertIsNone(self.run.paused)

    def test_kill_interruption_rejects_a_delivered_reply_or_settled_journal(self):
        for options in [dict(reply='{"ok":true}'), dict(status='succeeded'), dict(code=0)]:
            with self.subTest(**options):
                self.interrupt_patches(**options)
                with self.assertRaises(AssertionError):
                    self.run.interrupt(['c1', 'set'], harness.KILL)
                self.assertEqual(harness.os.kill.call_args_list[-1], unittest.mock.call(100, signal.SIGCONT))
                patch.stopall()

    def test_known_id_lookup_reports_absence_and_fails_on_other_errors(self):
        self.run.handlers = self.root / 'Handlers.applescript'
        self.run.handlers.write_text('on lookupVariantIdentities(docName, variantIDs)\nend lookupVariantIdentities\n')
        present = subprocess.CompletedProcess([], 0, f'2\tfalse\t\n1\ttrue\t{self.run.raw}\n', '')
        with patch.object(harness, 'ae', self.ae), patch.object(harness.subprocess, 'run', return_value=present) as run:
            rows = self.run.lookup_identities(['2', '1'])
        script = self.root / 'lookup-identities.applescript'
        self.assertEqual(run.call_args.args[0], ['osascript', str(script), str(self.run.session), '2', '1'])
        self.assertIn('on run argv', script.read_text())
        self.assertEqual(rows, [{'variantId': '2', 'isPresent': False, 'parentImagePath': ''},
                                {'variantId': '1', 'isPresent': True, 'parentImagePath': str(self.run.raw)}])
        # A coercion error (-1700) is a failed lookup, never absence.
        failed = subprocess.CompletedProcess([], 1, '', "Can't make id of variant id \"2\" into type text. (-1700)")
        with patch.object(harness, 'ae', self.ae), patch.object(harness.subprocess, 'run', return_value=failed):
            with self.assertRaises(AssertionError):
                self.run.lookup_identities(['2', '1'])

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.run = harness.Run.__new__(harness.Run)
        self.run.session = self.root / 'recovery'
        self.run.session.mkdir()
        self.run.db = self.run.session / 'recovery.cosessiondb'
        self.run.evidence = self.root
        self.run.journal = self.run.session / '.c1/journal.jsonl'
        self.run.raw = self.run.session / 'Capture/fixture.CR3'
        self.run.raw.parent.mkdir()
        self.run.raw.write_bytes(b'offline RAW fixture')
        self.run.raw_hash = harness.sha(self.run.raw)
        self.run.shutdown_mode = 'quit'
        self.run.restart_in_progress = False
        self.run.restart_number = 0
        self.run.owns_session = True
        self.run.hidden_bundle = self.run.paused = self.run.child = None
        self.run.log = Mock()
        self.run.fixture_snapshot = Mock()
        self.run.pid = Mock(side_effect=[100, 100, 200])
        self.calls = []

    def ae(self, body, timeout=30):
        self.calls.append(body)
        if body == 'return count of documents':
            return 0 if 'close first document' in self.calls and 'open' not in self.calls else 1
        if body == 'return id of first document':
            return str(self.run.session)

    def command(self, args, **kwargs):
        if args[0] == 'pgrep':
            return subprocess.CompletedProcess(args, 1, '', '')
        if args[0] == 'open':
            self.assertIn('-n', args)
            self.calls.append('open')
        return subprocess.CompletedProcess(args, 0, '', '')

    def wait(self, predicate, seconds=30):
        if not predicate():
            raise TimeoutError('offline deadline')
        return True

    def restart_patches(self):
        # Every external interaction used by restart is isolated here.
        for target, name, value in [
            (harness, 'ae', self.ae), (harness, 'wait_for', self.wait),
            (harness, 'process_exited', Mock(return_value=True)),
            (harness.subprocess, 'run', self.command), (harness.os, 'kill', Mock()),
        ]:
            p = patch.object(target, name, value)
            p.start()
            self.addCleanup(p.stop)

    def test_default_fixture_parent(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(harness.fixture_parent(), harness.ROOT / '.build/recovery-fixtures')

    def test_unsafe_fixture_parents(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        for parent in ['/tmp', '/tmp/recovery', '/private/tmp', '/private/tmp/recovery',
                       'relative/fixtures', str(alias / 'fixtures')]:
            with self.subTest(parent=parent), patch.dict(os.environ, C1_RECOVERY_FIXTURE_PARENT=parent):
                with self.assertRaises(ValueError):
                    harness.fixture_parent()

    def test_custom_fixture_parent(self):
        parent = harness.ROOT / '.build/custom-recovery-fixtures'
        with patch.dict(os.environ, C1_RECOVERY_FIXTURE_PARENT=str(parent)):
            self.assertEqual(harness.fixture_parent(), parent)

    def test_invalid_mode_rejected_before_setup(self):
        with patch.dict(os.environ, C1_RECOVERY_SHUTDOWN_MODE='automatic'), patch.object(harness, 'ae') as ae:
            with self.assertRaises(ValueError):
                harness.Run(self.root / 'archive', self.root / 'new-evidence')
            ae.assert_not_called()
            self.assertFalse((self.root / 'new-evidence').exists())

    def test_shutdown_defaults_to_process_termination(self):
        environment = {key: value for key, value in os.environ.items() if key != 'C1_RECOVERY_SHUTDOWN_MODE'}
        environment['C1_RECOVERY_FIXTURE_PARENT'] = str(self.root / 'fixtures')
        with patch.dict(os.environ, environment, clear=True), patch.object(harness, 'ae') as ae:
            run = harness.Run(self.root / 'archive', self.root / 'default-evidence')
            ae.assert_not_called()
        self.assertEqual(run.shutdown_mode, 'sigterm')

    def test_quit_success_observes_exit_before_open(self):
        self.restart_patches()
        harness.process_exited.side_effect = lambda pid: self.calls.append('exit-observed') or True
        self.run.restart()
        self.assertLess(self.calls.index('quit'), self.calls.index('exit-observed'))
        self.assertLess(self.calls.index('exit-observed'), self.calls.index('open'))
        harness.os.kill.assert_not_called()
        self.assertFalse(self.run.restart_in_progress)
        self.assertEqual(self.run.log.call_args.kwargs['shutdownKind'], 'native-quit')

    def test_sigterm_success_is_distinct(self):
        self.restart_patches()
        self.run.shutdown_mode = 'sigterm'
        self.run.restart()
        harness.os.kill.assert_called_once_with(100, signal.SIGTERM)
        self.assertNotIn('quit', self.calls)
        self.assertEqual(self.run.log.call_args.kwargs['shutdownKind'], 'process-termination')

    def test_launch_refuses_running_or_unknown_process_state(self):
        for code,output in [(0,'123\n'), (2,''), (1,'123\n')]:
            with self.subTest(code=code,output=output), patch.object(harness.subprocess, 'run', return_value=subprocess.CompletedProcess([],code,output,'')) as command:
                with self.assertRaisesRegex(AssertionError, 'Cannot prove'):
                    harness.launch_session(self.run.db)
                command.assert_called_once()

    def test_ownership_guards_prevent_shutdown(self):
        self.restart_patches()
        for count, document in [(2, self.run.session), (1, self.root / 'other')]:
            with self.subTest(count=count), patch.object(harness, 'ae', side_effect=lambda body, **kw:
                    count if body == 'return count of documents' else str(document)) as ae:
                with self.assertRaises(AssertionError):
                    self.run.restart()
                self.assertNotIn('close first document', [call.args[0] for call in ae.call_args_list])
                self.assertNotIn('quit', [call.args[0] for call in ae.call_args_list])
        harness.os.kill.assert_not_called()

    def test_zero_documents_required_after_close(self):
        self.restart_patches()
        self.run.shutdown_mode = 'sigterm'
        with patch.object(harness, 'ae', side_effect=lambda body, **kw:
                1 if body == 'return count of documents' else str(self.run.session)):
            with self.assertRaises(AssertionError):
                self.run.restart()
        harness.os.kill.assert_not_called()
        self.assertNotIn('open', self.calls)

    def test_changed_pid_prevents_signal(self):
        self.restart_patches()
        self.run.shutdown_mode = 'sigterm'
        self.run.pid.side_effect = [100, 101]
        with self.assertRaises(AssertionError):
            self.run.restart()
        harness.os.kill.assert_not_called()
        self.assertNotIn('open', self.calls)

    def test_quit_timeout_has_no_fallback_or_cleanup_events(self):
        self.restart_patches()
        normal = self.ae
        def timeout(body, **kwargs):
            if body == 'quit':
                raise subprocess.TimeoutExpired('osascript', 60)
            return normal(body, **kwargs)
        self.run.pid.side_effect = None
        self.run.pid.return_value = 100
        with patch.object(harness, 'ae', side_effect=timeout) as ae:
            with self.assertRaises(subprocess.TimeoutExpired):
                self.run.restart()
            ae.reset_mock()
            self.run.finish()
            ae.assert_not_called()
        harness.os.kill.assert_not_called()
        self.assertNotIn('open', self.calls)
        self.assertIn('shutdown-stalled', [call.args[0] for call in self.run.log.call_args_list])

    def test_process_exit_timeout_prevents_reopen_in_both_modes(self):
        self.restart_patches()
        for mode in ['quit', 'sigterm']:
            with self.subTest(mode=mode):
                self.calls.clear()
                self.run.shutdown_mode = mode
                self.run.pid.side_effect = None
                self.run.pid.return_value = 100
                harness.process_exited.return_value = False
                with self.assertRaises(TimeoutError):
                    self.run.restart()
                self.assertNotIn('open', self.calls)

    def test_sample_failure_preserves_original_timeout(self):
        self.restart_patches()
        harness.process_exited.return_value = False
        self.run.pid.side_effect = None
        self.run.pid.return_value = 100
        with patch.object(harness.subprocess, 'run', side_effect=OSError('sample failed')):
            with self.assertRaises(TimeoutError):
                self.run.restart()
        self.assertIn('shutdown-sample-failed', [call.args[0] for call in self.run.log.call_args_list])

    def test_failed_reopen_keeps_cleanup_suppressed(self):
        self.restart_patches()
        with patch.object(harness.subprocess, 'run', side_effect=OSError('open failed')):
            with self.assertRaises(OSError):
                self.run.restart()
        with patch.object(harness, 'ae') as ae:
            self.run.finish()
            ae.assert_not_called()

    def test_new_pid_required(self):
        self.restart_patches()
        self.run.pid.side_effect = [100, 100, 100]
        with self.assertRaises(AssertionError):
            self.run.restart()
        self.assertTrue(self.run.restart_in_progress)

    def test_permission_error_is_not_process_exit(self):
        with patch.object(harness.os, 'kill', side_effect=PermissionError):
            with self.assertRaises(PermissionError):
                harness.process_exited(100)
        with patch.object(harness.os, 'kill', side_effect=ProcessLookupError):
            self.assertTrue(harness.process_exited(100))

    def test_path_alias_rejected_before_inventory_can_be_used(self):
        self.run.cli = Mock(return_value=[{'id': '1', 'parentImagePath': '/tmp/aliased/fixture.CR3'}])
        with self.assertRaises(AssertionError):
            self.run.identities()

    def configure_recovery(self, after_ids=('1', '2'), operation_type='set', later=None, stalled=False):
        self.run.source = '1'
        self.run.original = {'stateHash': 'original', 'geometry': {'rotation': 0}}
        self.run.original_native = {'values': {'clarity amount': 0}, 'layers': []}
        entry = {'operationId': 'operation', 'operationType': operation_type, 'status': 'pending'}
        if stalled:
            entry.update(status='outcome-unknown', saveStalledAt='2026-10-13T00:00:00Z')
        self.run.records = Mock(return_value=[entry])
        self.run.pid = Mock(return_value=100)
        self.run.clone = Mock(return_value=({'workingRef': 'fresh'}, {'stateHash': 'fresh-state'}))
        self.restarted = False
        def restart():
            self.restarted = True
        self.run.restart = restart
        recorded = dict(adjustments={'exposure': 0.625}, geometry={'rotation': 0}, metadata={'rating': 0, 'colorTag': 0})
        reads = iter([recorded, later or recorded])
        def cli(*args, **kwargs):
            if args[:2] == ('variants', 'list'):
                return [{'id': i, 'parentImagePath': str(self.run.raw)}
                        for i in (after_ids if self.restarted else ['1', '2'])]
            if args[:2] == ('operation', 'status'):
                if self.restarted:
                    return {'status': 'reconciled', 'resolution': 'restart'}
                if operation_type == 'preview' or stalled:
                    return {'status': 'outcome-unknown'}
                return {'status': 'reconciled', 'resolution': 'probe-barrier', 'operationType': operation_type,
                        'workingRef': 'old-reference', 'nativeVariantId': '2', 'parentImagePath': str(self.run.raw),
                        'afterAdjustments': recorded['adjustments'], 'afterGeometry': recorded['geometry'],
                        'afterMetadata': recorded['metadata']}
            if args[:2] == ('variant', 'clone'):
                return {'error': {'code': 'outcome-unknown', 'operationId': 'operation'}}
            if args == ('get', 'old-reference'):
                if self.restarted:
                    return {'error': {'code': 'document-changed'}}
                observed = next(reads)
                return dict(observed['adjustments'] and {'adjustments': observed['adjustments']},
                            geometry=observed['geometry'], metadata=dict(observed['metadata'], camera='fixture'))
            if args == ('get', '1'):
                return dict(self.run.original)
            if args[:2] == ('get', '1'):
                return {'nativeSnapshots': [dict(self.run.original_native, nativeStateHash='revision')]}
            return {}
        self.run.cli = Mock(side_effect=cli)
        sleep = patch.object(harness.time, 'sleep')
        sleep.start()
        self.addCleanup(sleep.stop)

    def status_calls(self):
        return [c for c in self.run.cli.call_args_list if c.args[:2] == ('operation', 'status')]

    def test_changed_ids_or_count_stop_before_reconciliation_and_fresh_writes(self):
        # A covered kind would reconcile by barrier, and a landed preview could resolve late,
        # so only an uncovered non-preview write asks status before the restart.
        for operation_type, stalled, before_restart in [('set', False, 0), ('preview', False, 0), ('set', True, 1)]:
            for ids in [('1', '3'), ('1',), ('1', '2', '3')]:
                with self.subTest(operation_type=operation_type, stalled=stalled, ids=ids):
                    self.configure_recovery(ids, operation_type, stalled=stalled)
                    with self.assertRaisesRegex(AssertionError, 'native IDs, count'):
                        self.run.recovery('operation', {'workingRef': 'old-reference'}, 'test', harness.RESTART)
                    self.run.clone.assert_not_called()
                    self.assertEqual(len(self.status_calls()), before_restart)

    def test_uncovered_status_must_not_reconcile_before_restart(self):
        self.configure_recovery(stalled=True)
        normal = self.run.cli.side_effect
        def reconciles(*args, **kwargs):
            if args[:2] == ('operation', 'status') and not self.restarted:
                return {'status': 'reconciled', 'resolution': 'probe-barrier'}
            return normal(*args, **kwargs)
        self.run.cli.side_effect = reconciles
        with self.assertRaises(AssertionError):
            self.run.recovery('operation', {'workingRef': 'old-reference'}, 'test', harness.RESTART)
        self.assertFalse(self.restarted)

    def test_restart_recovery_retains_original_guards(self):
        self.configure_recovery()
        self.run.recovery('operation', {'workingRef': 'old-reference'}, 'test', harness.RESTART)
        self.assertTrue(self.restarted)
        self.run.cli.assert_any_call('get', 'old-reference', ok=False)
        self.run.cli.assert_any_call('variant', 'delete', 'fresh')
        self.run.clone.assert_called_once()

    def test_barrier_recovery_keeps_app_and_old_reference(self):
        self.configure_recovery()
        self.run.recovery('operation', {'workingRef': 'old-reference'}, 'test', harness.BARRIER)
        self.assertFalse(self.restarted)
        self.assertEqual(len(self.status_calls()), 1)
        reads = [c for c in self.run.cli.call_args_list if c.args == ('get', 'old-reference')]
        self.assertEqual(len(reads), 2, 'Barrier observation reads the old reference twice')
        harness.time.sleep.assert_called_once_with(2)
        self.run.cli.assert_any_call('variant', 'delete', 'fresh')

    def test_barrier_recovery_fails_on_restart_or_changing_observation(self):
        cases = [dict(later=dict(adjustments={'exposure': 0}, geometry={'rotation': 0}, metadata={'rating': 0, 'colorTag': 0})),
                 dict(operation_type='preview')]
        for options in cases:
            with self.subTest(**options):
                self.configure_recovery(**options)
                with self.assertRaises(AssertionError):
                    self.run.recovery('operation', {'workingRef': 'old-reference'}, 'test', harness.BARRIER)
                self.assertFalse(self.restarted)
                self.run.clone.assert_not_called()
        self.configure_recovery()
        self.run.pid = Mock(side_effect=[100, 101])
        with self.assertRaisesRegex(AssertionError, 'must not restart'):
            self.run.recovery('operation', {'workingRef': 'old-reference'}, 'test', harness.BARRIER)

    def test_barrier_observation_of_created_and_deleted_variants(self):
        self.run.identities = Mock(return_value=[('1', 'raw'), ('2', 'raw'), ('3', 'raw'), ('9', 'other')])
        self.run.cli = Mock(return_value={'adjustments': {}, 'metadata': {'rating': 0, 'colorTag': 0}})
        with patch.object(harness.time, 'sleep'):
            self.run.barrier_observation({'operationType': 'clone', 'parentImagePath': 'raw',
                                          'variantIdsBefore': ['1', '2'], 'observedVariantIds': ['3']})
            with self.assertRaises(AssertionError):
                self.run.barrier_observation({'operationType': 'clone', 'parentImagePath': 'raw',
                                              'variantIdsBefore': ['1', '2'], 'observedVariantIds': []})
            self.run.barrier_observation({'operationType': 'delete', 'parentImagePath': 'raw', 'nativeVariantId': '4'})
            with self.assertRaises(AssertionError):
                self.run.barrier_observation({'operationType': 'delete', 'parentImagePath': 'raw', 'nativeVariantId': '3',
                                              'workingRef': 'deleted-clone'})

    def test_preview_restart_path_reads_the_journal_before_restart(self):
        self.configure_recovery()
        preview = {'operationId': 'operation', 'operationType': 'preview', 'status': 'outcome-unknown'}
        self.run.records = Mock(return_value=[preview])
        self.run.recovery('operation', {'workingRef': 'old-reference'}, 'test', harness.RESTART)
        status = [c for c in self.run.cli.call_args_list if c.args[:2] == ('operation', 'status')]
        self.assertEqual(len(status), 1, 'Status runs only after the restart, so a landed JPEG cannot resolve first')
        self.run.records = Mock(return_value=[dict(preview, status='succeeded')])
        with self.assertRaises(AssertionError):
            self.run.recovery('operation', {'workingRef': 'old-reference'}, 'test', harness.RESTART)

    def configure_late_preview(self, resolution=None, pid=100, unresolved=0):
        folder = self.root / 'Output/c1-previews/op'
        folder.mkdir(parents=True)
        (folder / 'preview.jpg').write_bytes(b'\xff\xd8offline\xff\xd9')
        records = [{'operationId': 'op', 'operationType': 'preview', 'status': 'outcome-unknown', 'previewOutputPath': str(folder)}]
        resolved = dict({'status': 'succeeded', 'resolution': 'late-preview', 'previewOutputPath': str(folder / 'preview.jpg')}, **(resolution or {}))
        self.run.source = '1'
        self.run.records = Mock(side_effect=lambda: list(records))
        self.run.pid = Mock(return_value=pid)
        def cli(*args, **kwargs):
            if args[:2] == ('variant', 'clone'):
                return {'error': {'code': 'outcome-unknown', 'operationId': 'op'}}
            if args[:2] == ('operation', 'status'):
                if resolved['status'] != 'outcome-unknown' and len(records) == 1:
                    records.append(dict(records[0], **resolved))
                return resolved
            if args == ('doctor',):
                return {'unresolvedOperationsCount': unresolved, 'writesEnabled': not unresolved, 'allChecksPassed': not unresolved}
        self.run.cli = Mock(side_effect=cli)
        def observed(predicate, seconds=30):
            value = predicate()
            if not value:
                raise TimeoutError('offline deadline')
            return value
        patcher = patch.object(harness, 'wait_for', observed)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_late_preview_resolves_in_the_same_process(self):
        self.configure_late_preview()
        resolved = self.run.resolve_late_preview('op', 100)
        self.assertEqual(resolved['resolution'], 'late-preview')
        calls = [c.args[:2] for c in self.run.cli.call_args_list]
        self.assertLess(calls.index(('variant', 'clone')), calls.index(('operation', 'status')), 'The block is observed before status resolves it')

    def test_late_preview_fails_without_resolution_or_with_a_restart(self):
        for label, options in [('unresolved', {'resolution': {'status': 'outcome-unknown'}}),
                               ('reconciled', {'resolution': {'status': 'reconciled', 'resolution': None}}),
                               ('restarted', {'pid': 200}),
                               ('still blocked', {'unresolved': 1})]:
            with self.subTest(label), tempfile.TemporaryDirectory() as directory:
                self.root = Path(directory)
                self.configure_late_preview(**options)
                with self.assertRaises(AssertionError):
                    self.run.resolve_late_preview('op', 100)

    def test_keystone_reconciliation_accepts_observed_partial_write_and_preserves_ids(self):
        for observed in [[100,0,0,0,0], [100,12,0,0,0], [100,12,-7,0,0]]:
            with self.subTest(observed=observed):
                self.configure_recovery()
                normal = self.run.cli.side_effect
                def cli(*args, **kwargs):
                    if args[:2] == ('operation', 'status') and self.restarted:
                        return {'status':'reconciled', 'resolution': 'restart',
                                'requestedGeometry':{'keystone':{'vertical':12,'horizontal':-7}},
                                'beforeGeometry':{'keystone':[100,0,0,0,0],'lensGeometry':[0]},
                                'afterGeometry':{'keystone':observed,'lensGeometry':[0]}}
                    if args == ('get', 'fresh'):
                        return {'geometryStateHash':'fresh-geometry'}
                    return normal(*args, **kwargs)
                self.run.cli.side_effect = cli
                self.run.recovery('operation', {'workingRef':'old-reference'}, 'keystone', harness.RESTART, harness.check_keystone)
                self.run.clone.assert_called_once()
                self.run.cli.assert_any_call('variant', 'delete', 'fresh')

    def test_orientation_reconciliation_records_observations_then_turns_a_fresh_reference(self):
        planned = {'intendedGeometry': {'orientation': 90}}
        only = {'requestedGeometry': {'orientation': 90, 'rotation': 0}}
        for check, journaled, observed, accepted in [
                (harness.check_orientation, planned, 0, True),
                (harness.check_orientation, planned, 90, True),
                (harness.check_orientation_only, only, 90, True),
                (harness.check_orientation_only, only, 180, False),
                (harness.check_orientation, planned, 270, False)]:
            with self.subTest(check=check.__name__, observed=observed):
                self.configure_recovery()
                normal = self.run.cli.side_effect
                def cli(*args, **kwargs):
                    if args[:2] == ('operation', 'status') and self.restarted:
                        return dict(journaled, status='reconciled', resolution='restart', beforeGeometry={'orientation': 0, 'rotation': 0},
                                    afterGeometry={'orientation': observed, 'rotation': 0})
                    if args == ('get', 'fresh'):
                        return {'stateHash': 'fresh-state', 'geometryStateHash': 'fresh-geometry', 'geometry': {'orientation': 270}}
                    if args[:3] == ('geometry', 'set', 'fresh'):
                        return {'after': {'orientation': 270}}
                    return normal(*args, **kwargs)
                self.run.cli.side_effect = cli
                recover = lambda: self.run.recovery('operation', {'workingRef': 'old-reference'}, 'orientation', harness.RESTART,
                                                    check, harness.resume_orientation)
                if accepted:
                    recover()
                    self.run.cli.assert_any_call('geometry', 'set', 'fresh', '--if-geometry-state', 'fresh-geometry', '--orientation', '270')
                    self.run.cli.assert_any_call('variant', 'delete', 'fresh')
                else:
                    with self.assertRaises(AssertionError):
                        recover()
                    self.run.clone.assert_not_called()

    def test_changed_original_state_or_geometry_still_fails(self):
        for changed in [{'stateHash': 'changed', 'geometry': {'rotation': 0}},
                        {'stateHash': 'original', 'geometry': {'rotation': 3}}]:
            with self.subTest(changed=changed):
                self.configure_recovery()
                normal = self.run.cli.side_effect
                self.run.cli.side_effect = lambda *args, **kw: changed if args == ('get', '1') else normal(*args, **kw)
                with self.assertRaises(AssertionError):
                    self.run.recovery('operation', {'workingRef': 'old-reference'}, 'test', harness.RESTART)
                self.run.clone.assert_not_called()

    def test_snapshot_is_read_only_and_retains_duplicate_relationships(self):
        with sqlite3.connect(self.run.db) as db:
            db.executescript('''
                CREATE TABLE ZIMAGE (Z_PK, ZIMAGEUUID, ZIMAGELOCATION, ZIMAGEFILENAME);
                CREATE TABLE ZPATHLOCATION (Z_PK, ZMACROOT, ZRELATIVEPATH, ZISRELATIVE);
                CREATE TABLE ZVARIANT (Z_PK, ZIMAGE, ZINDEX, ZVARIANTUUID);
                INSERT INTO ZIMAGE VALUES (1, 'same-raw', 1, 'fixture.CR3'), (2, 'same-raw', 2, 'fixture.CR3');
                INSERT INTO ZPATHLOCATION VALUES (1, '', 'Capture', 1), (2, '', 'Capture', 1);
                INSERT INTO ZVARIANT VALUES (1, 1, 127, 'v1'), (2, 2, 127, 'v1');
            ''')
        before = harness.sha(self.run.db)
        harness.Run.fixture_snapshot(self.run, 'closed')
        self.assertEqual(harness.sha(self.run.db), before)
        data = json.loads((self.root / 'restart-0-closed.json').read_text())
        self.assertEqual(len(data['images']), 2)
        self.assertEqual(data['quickCheck'], 'ok')

    def test_corrected_lens_fixture_is_journaled_before_dispatch(self):
        self.run.journal.parent.mkdir()
        self.run.records = Mock(return_value=[{'operationId': 'old', 'status': 'succeeded'}])
        self.run.cli = Mock(side_effect=[{'id':'12', 'geometry':{'lensGeometry':[0]}},
                                        {'id':'12', 'geometry':{'lensGeometry':[100]}}])
        def dispatched(script):
            pending = json.loads(self.run.journal.read_text().splitlines()[-1])
            self.assertEqual(pending['status'], 'pending')
            self.assertEqual(pending['nativeVariantId'], '12')
            self.assertIn('variant id "12"', script)
        with patch.object(harness, 'ae', side_effect=dispatched):
            observed = self.run.enable_lens_correction({'workingRef':'owned'})
        self.assertEqual(observed['geometry']['lensGeometry'], [100])
        self.assertEqual(json.loads(self.run.journal.read_text().splitlines()[-1])['status'], 'succeeded')

    def test_perspective_fixture_checks_movements_and_keystone(self):
        self.run.journal.parent.mkdir()
        self.run.records = Mock(return_value=[{'operationId': 'old', 'status': 'succeeded'}])
        expected = {'lensGeometry':[100,45,2,45,3,90,2,-2], 'keystone':[100,10,-5,0,0]}
        self.run.cli = Mock(side_effect=[{'id':'12', 'geometry':{}}, {'id':'12', 'geometry':expected}])
        def dispatched(script):
            self.assertEqual(json.loads(self.run.journal.read_text().splitlines()[-1])['status'], 'pending')
            self.assertIn('Phase One 45mm TS f/3.5', script)
            self.assertIn('keystone vertical', script)
            self.assertIn('shift y', script)
        with patch.object(harness, 'ae', side_effect=dispatched):
            self.run.enable_lens_correction({'workingRef':'owned'}, perspective=True)
        self.assertEqual(json.loads(self.run.journal.read_text().splitlines()[-1])['afterGeometry'], expected)

    def test_failed_corrected_lens_fixture_retains_pending_block(self):
        self.run.journal.parent.mkdir()
        self.run.records = Mock(return_value=[{'operationId': 'old', 'status': 'succeeded'}])
        self.run.cli = Mock(return_value={'id':'12', 'geometry':{'lensGeometry':[0]}})
        with patch.object(harness, 'ae', side_effect=TimeoutError('unknown')):
            with self.assertRaises(TimeoutError):
                self.run.enable_lens_correction({'workingRef':'owned'})
        self.assertEqual(len(self.run.journal.read_text().splitlines()), 1)
        self.assertEqual(json.loads(self.run.journal.read_text())['status'], 'pending')


if __name__ == '__main__':
    unittest.main()
