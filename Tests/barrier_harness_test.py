#!/usr/bin/env python3
"""Offline barrier-qualification safeguards; never contacts Capture One."""
from pathlib import Path
import signal
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call, patch

import barrier_integration_test as barrier
import recovery_integration_test as harness


def record(timed_out=True, probe=0, before='0', after_probe='1', final='1'):
    return dict(timedOut=timed_out, probe=dict(code=probe), landed=final != before,
                barrierHeld=after_probe == final, informative=timed_out and final != before)


class VerdictTests(unittest.TestCase):
    def test_queued_kind_needs_every_trial_queued_landed_and_held(self):
        self.assertEqual(barrier.verdict(barrier.QUEUED, [record(), record()])[1], [])
        for broken in [record(timed_out=False), record(probe=1), record(final='0', after_probe='0'), record(after_probe='0')]:
            with self.subTest(broken=broken):
                self.assertTrue(barrier.verdict(barrier.QUEUED, [record(), broken])[1])

    def test_running_kind_judges_only_trials_that_timed_out(self):
        finished_early = record(timed_out=False, after_probe='0')
        self.assertEqual(barrier.verdict(barrier.RUNNING, [finished_early, record()])[1], [])
        self.assertTrue(barrier.verdict(barrier.RUNNING, [record(after_probe='0')])[1])

    def test_control_must_break_the_barrier_at_least_once(self):
        summary, failures = barrier.verdict(barrier.CONTROL, [record(), record(after_probe='0')])
        self.assertEqual((summary['broken'], failures), (1, []))
        self.assertTrue(barrier.verdict(barrier.CONTROL, [record(), record()])[1])

    def test_every_barrier_covered_action_has_a_qualifying_kind(self):
        self.assertLessEqual(harness.BARRIER_ACTIONS, set(barrier.KINDS))
        self.assertFalse(set(barrier.UNQUALIFIABLE) & harness.BARRIER_ACTIONS)


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.run = barrier.BarrierRun.__new__(barrier.BarrierRun)
        self.run.work = Path(self.temporary.name).resolve()
        self.run.session = self.run.work / 'barrier'
        self.run.evidence = self.run.work / 'evidence'
        self.run.evidence.mkdir()
        self.run.recipe = 'c1-barrier-test'
        self.run.recipe_created = True
        self.run.owns_session = True
        self.run.paused = None
        self.run.summary = {}
        self.run.log = Mock()

    def test_cleanup_never_closes_another_document(self):
        self.run.recipe_created = False
        def ok(body, seconds=60):
            return {'return count of documents': '1', 'return id of first document': '"/elsewhere/other"'}.get(body, '')
        with patch.object(barrier, 'ok', side_effect=ok) as script:
            self.run.finish()
        self.assertNotIn('close first document', [c.args[0] for c in script.call_args_list])

    def test_recipe_outside_the_fixture_is_never_deleted(self):
        with patch.object(barrier, 'ok', return_value='"/Users/someone/Exports/"') as script:
            with self.assertRaises(AssertionError):
                self.run.delete_recipe()
        self.assertFalse(any(c.args[0].startswith('delete recipe') for c in script.call_args_list))

    def test_paused_trial_always_resumes(self):
        self.run.pid = Mock(return_value=100)
        kind = barrier.Kind('raw', lambda t: 'set rating of v to 1', lambda t: 'return rating of v')
        with patch.object(barrier, 'osa', side_effect=[dict(code=0, out='0', err=''), RuntimeError('writer failed')]), \
             patch.object(barrier.subprocess, 'Popen', return_value=Mock()), patch.object(barrier.os, 'kill') as kill:
            with self.assertRaises(RuntimeError):
                self.run.trial('rating', kind, SimpleNamespace(v='v', i=0, target=None), barrier.QUEUED)
        self.assertEqual(kill.call_args_list, [call(100, signal.SIGSTOP), call(100, signal.SIGCONT)])
        self.assertIsNone(self.run.paused)


if __name__ == '__main__':
    unittest.main()
