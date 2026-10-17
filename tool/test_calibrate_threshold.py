#!/usr/bin/env python3
"""Tests the calibration LOGIC with synthetic numbers. These numbers say
nothing about any real face model."""
import importlib.util
import os
import random
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("calibrate_threshold", os.path.join(HERE, "calibrate_threshold.py"))
cal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cal)


class ChooseTest(unittest.TestCase):
    def test_refuses_too_few_genuine(self):
        res, why = cal.choose([0.8] * 10, [0.1] * 20000, 0.001)
        self.assertIsNone(res)
        self.assertIn("genuine", why)

    def test_refuses_too_few_impostor_for_target(self):
        res, why = cal.choose([0.8] * 200, [0.1] * 500, 0.001)
        self.assertIsNone(res)
        self.assertIn("impostor", why)

    def test_rejects_bad_target(self):
        for far in (0, 1, -0.1, 2):
            res, why = cal.choose([0.8] * 200, [0.1] * 20000, far)
            self.assertIsNone(res)

    def test_threshold_meets_target_on_supplied_data(self):
        rnd = random.Random(7)
        genuine = [rnd.gauss(0.7, 0.1) for _ in range(500)]
        impostor = [rnd.gauss(0.1, 0.1) for _ in range(20000)]
        res, why = cal.choose(genuine, impostor, 0.001)
        self.assertIsNone(why)
        self.assertLessEqual(res["measured_far"], 0.001)
        self.assertGreater(res["threshold"], 0.1)

    def test_nothing_accepted_above_threshold_when_far_tiny(self):
        impostor = [i / 100000 for i in range(20000)]
        genuine = [0.9] * 200
        res, why = cal.choose(genuine, impostor, 0.0005)
        self.assertLessEqual(res["measured_far"], 0.0005)


if __name__ == "__main__":
    unittest.main()
