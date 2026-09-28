#!/usr/bin/env python3
import importlib.util
import json
import math
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('planner', ROOT / 'scripts/propose-contained-crop.py')
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)
# Shared with GeometryTests.swift, so the planner and c1 apply one containment test.
CASES = json.loads((ROOT / 'Tests/fixtures/crop-containment.json').read_text())
CORNERS = ((-1, -1), (1, -1), (1, 1), (-1, 1))


def corner_indices(crop, exposed):
    return [i for i, (sx, sy) in enumerate(CORNERS)
            if any(math.isclose(e['x'], crop['centerX'] + sx*crop['width']/2) and
                   math.isclose(e['y'], crop['centerY'] + sy*crop['height']/2) for e in exposed)]


class ContainmentTableTests(unittest.TestCase):
    def test_table(self):
        for case in CASES:
            with self.subTest(case['name']):
                size = case['canvas']
                exposed = planner.exposed_corners(case['crop'], case['rotation'], size['width'], size['height'])
                self.assertEqual(corner_indices(case['crop'], exposed), case['exposed'])
                self.assertEqual([round(e['distance'], 3) for e in exposed], case['distances'])

    def test_proposals_are_contained(self):
        for case in CASES:
            with self.subTest(case['name']):
                size = case['canvas']
                result = planner.propose(case['crop'], case['rotation'], size['width'], size['height'])
                r = result['proposed']
                self.assertEqual(planner.exposed_corners(r, case['rotation'], size['width'], size['height'], tolerance=0), [])
                self.assertAlmostEqual(result['proposedAspectRatio'], result['originalAspectRatio'])
                self.assertLessEqual(result['scale'], 1)
                self.assertFalse(result['applied'])
                strict = planner.exposed_corners(case['crop'], case['rotation'], size['width'], size['height'], tolerance=0)
                self.assertEqual(result['status'], 'normalized-proposal' if strict else 'unchanged')


class ProposalTests(unittest.TestCase):
    def test_rotated_off_centre_moves_without_scaling(self):
        # Fits at full size once moved: only the centre changes, along the image edge.
        mirrored = next(c for c in CASES if c['name'] == 'same off-centre crop at -20 degrees')
        result = planner.propose(mirrored['crop'], -20, 6000, 4000)
        self.assertEqual(result['status'], 'normalized-proposal')
        self.assertEqual(result['scale'], 1)
        self.assertAlmostEqual(result['proposed']['width'], mirrored['crop']['width'], places=4)
        self.assertLess(math.hypot(result['delta']['centerX'], result['delta']['centerY']), 130)

    def test_oversized_crop_scales_to_the_centred_fit(self):
        crop = dict(centerX=3400, centerY=2200, width=6000, height=4000)
        result = planner.propose(crop, 5, 6000, 4000)
        self.assertLess(result['scale'], 1)
        self.assertTrue(result['exposedCorners'])
        c, s = math.cos(math.radians(5)), math.sin(math.radians(5))
        # The height binds, so the centre may still slide along the image's long axis.
        self.assertAlmostEqual(result['scale'], 4000 / (6000*s + 4000*c), places=9)

    def test_plan_uses_oriented_canvas_or_native_bounds(self):
        geometry = dict(crop=None, rotation=10, orientation=90, imageWidth=6000, imageHeight=4000,
                        lensGeometry=[0, 35, 0, 0, 0, 0, 0, 0], keystone=[100, 0, 0, 0, 0],
                        maximumCrop=dict(centerX=3000, centerY=2000, width=5000, height=3400))
        crop = dict(centerX=2400, centerY=3500, width=3000, height=4000)
        self.assertEqual(planner.plan(crop, geometry)['canvas'], dict(width=4000, height=6000))
        corrected = dict(geometry, lensGeometry=[50, 35, 0, 0, 0, 0, 0, 0])
        self.assertEqual(planner.plan(crop, corrected)['bounds'], geometry['maximumCrop'])

    def test_native_bounds_fit(self):
        crop = dict(centerX=3400, centerY=2200, width=5400, height=3600)
        bounds = dict(centerX=3000, centerY=2000, width=5000, height=3400)
        result = planner.propose_in_bounds(crop, bounds)
        self.assertEqual(result['status'], 'normalized-proposal')
        self.assertEqual(result['delta']['centerX'], -400)
        self.assertAlmostEqual(result['proposedAspectRatio'], 1.5)
        self.assertEqual(crop['width'], 5400)
        for width in (5000.1, 6000.0, 1.0):
            bounds = dict(centerX=3000.1, centerY=2000.3, width=width, height=4000.7)
            for x in (bounds['centerX'] - 2, bounds['centerX'] + 2, math.nextafter(bounds['centerX'] + 2, math.inf)):
                r = planner.propose_in_bounds(dict(centerX=x, centerY=2200, width=width+4, height=2000), bounds)['proposed']
                for center, size in (('centerX', 'width'), ('centerY', 'height')):
                    self.assertLessEqual(abs(r[center]-bounds[center])+r[size]/2, bounds[size]/2)

    def test_invalid(self):
        rect = dict(centerX=3000, centerY=2000, width=6000, height=4000)
        self.assertEqual(planner.propose(rect, 0, 6000, 4000)['status'], 'unchanged')
        for value in (float('nan'), float('inf'), True):
            with self.assertRaises(ValueError):
                planner.propose(dict(rect, centerX=value), 0, 6000, 4000)
            with self.assertRaises(ValueError):
                planner.propose(rect, value, 6000, 4000)


if __name__ == '__main__':
    unittest.main()
