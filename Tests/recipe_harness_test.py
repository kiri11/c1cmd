#!/usr/bin/env python3
"""Offline selection and failure isolation for the compound recovery harness."""
import unittest
from unittest.mock import Mock
from recipe_recovery_integration_test import RecipeRun


class RecipeHarnessTests(unittest.TestCase):
    def test_selected_cases_only(self):
        runner = RecipeRun.__new__(RecipeRun)
        runner.compound_fault = Mock()
        runner.run_cases(['native','mcp-death'])
        self.assertEqual([c.args for c in runner.compound_fault.call_args_list],[('native',),('mcp-death',)])

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
