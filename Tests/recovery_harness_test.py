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
        self.assertEqual(harness.parse_args(['archive', 'evidence']).cases, list(harness.RECOVERY_CASES))
        self.assertEqual(harness.selected_cases(['preview', 'clone-readback']), ['clone-readback', 'preview'])
        for cases in [[], ['unknown'], ['preview', 'preview'], ['all', 'preview']]:
            with self.subTest(cases=cases), patch.object(harness, 'Run') as run, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    harness.main(['archive', 'evidence', '--cases', *cases])
                self.assertEqual(error.exception.code, 2)
                run.assert_not_called()

    def test_selected_faults_skip_unrelated_stress_and_timeouts(self):
        self.run.apple_event_timeout = Mock()
        self.run.preview_timeout = Mock()
        self.run.mcp_death = Mock()
        self.run.clone = Mock()
        self.run.run_cases(['preview', 'mcp-death'])
        self.run.preview_timeout.assert_called_once_with()
        self.run.mcp_death.assert_called_once_with()
        self.run.apple_event_timeout.assert_not_called()
        self.run.clone.assert_not_called()

    def test_case_failure_stops_without_dispatching_next_fault(self):
        self.run.apple_event_timeout = Mock(side_effect=TimeoutError('recovery failed'))
        self.run.preview_timeout = Mock()
        with self.assertRaises(TimeoutError):
            self.run.run_cases(['lens', 'preview'])
        self.run.apple_event_timeout.assert_called_once_with(geometry=True, corrected=True)
        self.run.preview_timeout.assert_not_called()

    def test_full_case_dispatch_preserves_original_campaign(self):
        calls = []
        self.run.clone = Mock(return_value=({'workingRef': 'clone'}, {}))
        self.run.cli = Mock(return_value=[{'id': '1'}])
        self.run.apple_event_timeout = lambda **kw: calls.append(('timeout', kw))
        self.run.preview_timeout = lambda: calls.append(('preview', {}))
        self.run.mcp_death = lambda: calls.append(('mcp-death', {}))
        self.run.run_cases(['all'])
        self.assertEqual(self.run.clone.call_count, 10)
        self.assertEqual(calls, [('timeout', {}), ('timeout', {'native': True}), ('timeout', {'native_action': True}), ('timeout', {'geometry': True}),
                               ('timeout', {'geometry': True, 'corrected': True}),
                               ('timeout', {'geometry': True, 'perspective': True}),
                               ('timeout', {'geometry': True, 'keystone': True}),
                               ('preview', {}), ('mcp-death', {})])

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

    def configure_recovery(self, after_ids=('1', '2')):
        self.run.source = '1'
        self.run.original = {'stateHash': 'original', 'geometry': {'rotation': 0}}
        self.run.records = Mock(return_value=[])
        self.run.clone = Mock(return_value=({'workingRef': 'fresh'}, {'stateHash': 'fresh-state'}))
        self.restarted = False
        def restart():
            self.restarted = True
        self.run.restart = restart
        def cli(*args, **kwargs):
            if args[:2] == ('variants', 'list'):
                return [{'id': i, 'parentImagePath': str(self.run.raw)}
                        for i in (after_ids if self.restarted else ['1', '2'])]
            if args[:2] == ('operation', 'status'):
                return {'status': 'reconciled' if self.restarted else 'outcome-unknown'}
            if args[:2] == ('variant', 'clone'):
                return {'error': {'code': 'outcome-unknown', 'operationId': 'operation'}}
            if args == ('get', 'old-reference'):
                return {'error': {'code': 'document-changed'}}
            if args == ('get', '1'):
                return dict(self.run.original)
            return {}
        self.run.cli = Mock(side_effect=cli)

    def test_changed_ids_or_count_stop_before_reconciliation_and_fresh_writes(self):
        for ids in [('1', '3'), ('1',), ('1', '2', '3')]:
            with self.subTest(ids=ids):
                self.configure_recovery(ids)
                with self.assertRaisesRegex(AssertionError, 'native IDs, count'):
                    self.run.recovery('operation', {'workingRef': 'old-reference'}, 'test')
                self.run.clone.assert_not_called()
                status = [c for c in self.run.cli.call_args_list if c.args[:2] == ('operation', 'status')]
                self.assertEqual(len(status), 1, 'Only pre-restart status may run')

    def test_recovery_with_preserved_ids_retains_original_guards(self):
        self.configure_recovery()
        self.run.recovery('operation', {'workingRef': 'old-reference'}, 'test')
        self.run.cli.assert_any_call('get', 'old-reference', ok=False)
        self.run.cli.assert_any_call('variant', 'delete', 'fresh')
        self.run.clone.assert_called_once()

    def test_keystone_reconciliation_accepts_observed_partial_write_and_preserves_ids(self):
        for observed in [[100,0,0,0,0], [100,12,0,0,0], [100,12,-7,0,0]]:
            with self.subTest(observed=observed):
                self.configure_recovery()
                normal = self.run.cli.side_effect
                def cli(*args, **kwargs):
                    if args[:2] == ('operation', 'status') and self.restarted:
                        return {'status':'reconciled',
                                'requestedGeometry':{'keystone':{'vertical':12,'horizontal':-7}},
                                'beforeGeometry':{'keystone':[100,0,0,0,0],'lensGeometry':[0]},
                                'afterGeometry':{'keystone':observed,'lensGeometry':[0]}}
                    if args == ('get', 'fresh'):
                        return {'geometryStateHash':'fresh-geometry'}
                    return normal(*args, **kwargs)
                self.run.cli.side_effect = cli
                self.run.recovery('operation', {'workingRef':'old-reference'}, 'keystone-geometry-apple-event-timeout')
                self.run.clone.assert_called_once()
                self.run.cli.assert_any_call('variant', 'delete', 'fresh')

    def test_changed_original_state_or_geometry_still_fails(self):
        for changed in [{'stateHash': 'changed', 'geometry': {'rotation': 0}},
                        {'stateHash': 'original', 'geometry': {'rotation': 3}}]:
            with self.subTest(changed=changed):
                self.configure_recovery()
                normal = self.run.cli.side_effect
                self.run.cli.side_effect = lambda *args, **kw: changed if args == ('get', '1') else normal(*args, **kw)
                with self.assertRaises(AssertionError):
                    self.run.recovery('operation', {'workingRef': 'old-reference'}, 'test')
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
