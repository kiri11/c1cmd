#!/usr/bin/env python3
import importlib.util
import math
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('planner', Path(__file__).resolve().parents[1] / 'scripts/propose-contained-crop.py')
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


class ContainedCropTests(unittest.TestCase):
    def test_off_center_proportional_fit(self):
        crop = dict(centerX=3400, centerY=2200, width=5400, height=3600)
        bounds = dict(centerX=3000, centerY=2000, width=5000, height=3400)
        result = planner.propose(crop, bounds)
        self.assertEqual(result['status'], 'normalized-proposal')
        self.assertEqual(result['delta']['centerX'], -400)
        self.assertAlmostEqual(result['proposedAspectRatio'], 1.5)
        self.assertFalse(result['applied'])
        self.assertEqual(crop['width'], 5400)

    def test_fractional_full_width_and_edge_neighbors(self):
        for width in (5000.1, 6000.0, 1.0):
            bounds = dict(centerX=3000.1, centerY=2000.3, width=width, height=4000.7)
            for x in (bounds['centerX'] - 2, bounds['centerX'] + 2,
                      math.nextafter(bounds['centerX'] + 2, math.inf)):
                crop = dict(centerX=x, centerY=2200, width=width+4, height=2000)
                result = planner.propose(crop, bounds)
                r = result['proposed']
                for center, size in (('centerX', 'width'), ('centerY', 'height')):
                    self.assertLessEqual(abs(r[center]-bounds[center])+r[size]/2, bounds[size]/2)
                self.assertAlmostEqual(r['width']/r['height'], crop['width']/crop['height'])

    def test_unchanged_and_invalid(self):
        rect = dict(centerX=3000, centerY=2000, width=6000, height=4000)
        self.assertEqual(planner.propose(rect, rect)['status'], 'unchanged')
        for value in (float('nan'), float('inf'), True):
            with self.assertRaises(ValueError):
                planner.propose(dict(rect, centerX=value), rect)


if __name__ == '__main__':
    unittest.main()
