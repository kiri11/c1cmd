#!/usr/bin/env python3
"""Check the native bounds probe's classification without Capture One."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('native_bounds_probe', ROOT / 'scripts/probe-native-bounds.py')
probe = importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)


def write(written, read_back, error=None):
    return dict(written=written, readBack=read_back, error=error)


class ClassifyTests(unittest.TestCase):
    def test_rejected_past_value_confirms(self):
        self.assertEqual(probe.classify('exposure', write(4, 4.0), write(4.01, 4.0, 'Cannot set')), 'confirmed')

    def test_accepted_past_value_is_a_mismatch(self):
        self.assertEqual(probe.classify('brightness', write(50, 50.0), write(51, 51.0)), 'mismatch')

    def test_error_with_the_past_value_applied_is_a_mismatch(self):
        self.assertEqual(probe.classify('brightness', write(50, 50.0), write(51, 51.0, 'Cannot set')), 'mismatch')

    def test_rejected_bound_is_a_mismatch(self):
        self.assertEqual(probe.classify('level highlight rgb', write(255, 250.0, 'Cannot set'), write(256, 250.0, 'Cannot set')), 'mismatch')
        self.assertEqual(probe.classify('level highlight rgb', write(255, 250.0), write(256, 250.0, 'Cannot set')), 'mismatch')

    def test_silent_hue_clamp_confirms_clamped(self):
        self.assertEqual(probe.classify('color balance master hue', write(360, 360.0), write(361, 360.0)), 'confirmed-clamped')

    def test_hue_is_circular(self):
        self.assertEqual(probe.classify('color balance master hue', write(0, 360.0), write(-1, 359.0)), 'mismatch')

    def test_tolerances(self):
        self.assertEqual(probe.classify('tint', write(50, 49.995), write(51, 49.995, 'x')), 'confirmed')
        self.assertEqual(probe.classify('exposure', write(4, 3.999), write(4.01, 4.0, 'x')), 'mismatch')
        self.assertEqual(probe.classify('temperature', write(14000, 14000.05), write(14001, 14000.0, 'x')), 'confirmed')

    def test_missing_read_back(self):
        self.assertEqual(probe.classify('exposure', write(4, None), write(4.01, None, 'x')), 'mismatch')

    def test_step_and_partner(self):
        self.assertEqual(probe.step('real', .2, 2.5), .01)
        self.assertEqual(probe.step('real', 0, 100), 1)
        self.assertEqual(probe.step('integer', 4, 10), 1)
        self.assertEqual(probe.partner('level target highlight red'), 'level target shadow red')
        self.assertEqual(probe.partner('level shadow rgb'), 'level highlight rgb')
        self.assertIsNone(probe.partner('level midtone rgb'))
        self.assertIsNone(probe.partner('black and white split shadow hue'))

    def test_literal(self):
        self.assertEqual([probe.literal(v) for v in (-101, 2.51, 14000.0, 0.19)], ['-101', '2.51', '14000', '0.19'])


if __name__ == '__main__':
    unittest.main()
