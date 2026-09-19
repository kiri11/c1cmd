#!/usr/bin/env python3
"""Offline selection and failure isolation for the compound recovery harness."""
import unittest
import json
from pathlib import Path
from unittest.mock import Mock, patch
from recipe_recovery_integration_test import RecipeRun, parse_args, CASES


class RecipeHarnessTests(unittest.TestCase):
    def test_native_readiness_retries_only_read_only_launch_race(self):
        runner = RecipeRun.__new__(RecipeRun)
        runner.c1 = Path('/fixture/c1'); runner.session = Path('/fixture/session'); runner.log = Mock()
        missing = Mock(returncode=5,stdout=json.dumps({'error':{'code':'app-not-running'}}),stderr='')
        ready = Mock(returncode=0,stdout=json.dumps({'documentPath':'/fixture/session'}),stderr='')
        with patch('recipe_recovery_integration_test.subprocess.run',side_effect=[missing,ready,ready,ready]) as run, patch('recipe_recovery_integration_test.time.sleep'):
            runner.wait_native_document()
        self.assertEqual(run.call_count,4)
        self.assertTrue(all(c.args[0][1:]==['doc','info','--format','json'] for c in run.call_args_list))

    def test_native_readiness_rejects_other_errors_and_wrong_document(self):
        runner = RecipeRun.__new__(RecipeRun)
        runner.c1 = Path('/fixture/c1'); runner.session = Path('/fixture/session'); runner.log = Mock()
        for code,value in [(5,{'error':{'code':'outcome-unknown'}}),(0,{'documentPath':'/other'})]:
            with patch('recipe_recovery_integration_test.subprocess.run',return_value=Mock(returncode=code,stdout=json.dumps(value),stderr='')) as run:
                with self.assertRaises(AssertionError): runner.wait_native_document()
                run.assert_called_once()

    def test_selected_cases_only(self):
        runner = RecipeRun.__new__(RecipeRun)
        runner.compound_fault = Mock()
        self.assertEqual(runner.select_cases(["layer-color"]),["layer-color"])
        runner.run_cases(['native','native-action','lens','layer-color','mcp-death'])
        self.assertEqual([c.args for c in runner.compound_fault.call_args_list],[('native',),('native-action',),('lens',),('layer-color',),('mcp-death',)])

    def test_case_parser(self):
        self.assertEqual(parse_args(['archive','evidence','--cases','all']).cases,list(CASES))
        self.assertEqual(parse_args(['archive','evidence','--cases','layer-color']).cases,['layer-color'])
        with self.assertRaises(SystemExit): parse_args(['archive','evidence','--cases','native','native'])

    def test_failure_stops_campaign(self):
        runner = RecipeRun.__new__(RecipeRun)
        runner.compound_fault = Mock(side_effect=RuntimeError('unresolved operation'))
        with self.assertRaises(RuntimeError):
            runner.run_cases(['native','geometry'])
        runner.compound_fault.assert_called_once_with('native')

    def test_unrelated_fault_rejected(self):
        runner = RecipeRun.__new__(RecipeRun)
        runner.compound_fault = Mock()
        with self.assertRaises(AssertionError):
            runner.run_cases(['clone-readback'])
        runner.compound_fault.assert_not_called()


if __name__ == '__main__': unittest.main()
