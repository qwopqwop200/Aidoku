#!/usr/bin/env python3
"""Compiler-free contact geometry regression using native Core Graphics.

Evaluate the four CGRect constructor expressions read from production, not a
copied window generator. Backing and consumer bounds are source contracts only;
this does not execute Card commits, typography, or rendering. The straddling
fixtures currently expose negative-size contacts occupying the bounded prefix.
"""

import ctypes
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "Aidoku/Core/Translation/NativeEngine/Overlay"
SOURCE = (OVERLAY / "NativeTranslationRenderer+BalloonPanelContainment.swift").read_text()
CG = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")


class Point(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class Size(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


class Rect(ctypes.Structure):
    _fields_ = [("origin", Point), ("size", Size)]


for attribute in ("minX", "minY", "maxX", "maxY", "width", "height"):
    function = getattr(CG, "CGRectGet" + attribute[0].upper() + attribute[1:])
    function.argtypes = [Rect]
    function.restype = ctypes.c_double
    setattr(Rect, attribute, property(lambda self, function=function: function(self)))


def rect(x, y, width, height):
    return Rect(Point(x, y), Size(width, height))


def contact_rectangles(panel, ink):
    block = SOURCE.split("let contacts = [", 1)[1].split("\n                        ]", 1)[0]
    expressions = re.findall(
        r"CGRect\(x: ([^,]+), y: ([^,]+), width: ([^,]+), height: ([^)]+)\)", block
    )
    if len(expressions) != 4:
        raise AssertionError("Production contact constructors changed; adapt this focused evaluator")
    for values in expressions:
        coordinates = []
        for expression in values:
            if not re.fullmatch(r"[a-zA-Z. +\-]+", expression):
                raise AssertionError("Unsupported production contact expression")
            coordinates.append(eval(expression, {"__builtins__": {}}, {"panel": panel, "ink": ink}))
        yield rect(*coordinates)


class ContactWindows(unittest.TestCase):
    def test_layout_only_backing_is_panel_not_contact_frame(self):
        self.assertIn("layoutOnly ? [original.sourcePlateRect]", SOURCE)
        self.assertIn("proposal.sourcePlateOwnerRect = panel; proposal.straightenedPanelRect = panel", SOURCE)
        self.assertIn("proposal.textBoxBackgroundClip = nil", SOURCE)
        self.assertNotRegex(SOURCE, r"proposal\.(sourcePlateOwnerRect|straightenedPanelRect)\s*=\s*(textFrame|window|contact)")

    def test_consumed_candidate_bound(self):
        # At most 17 windows * 4 widths * (one inscribed + eight frontier frames).
        # This bounds consumed frames, not the preceding peer enumeration work.
        window_limit = re.search(r"for window in windows\.prefix\((\d+)\)", SOURCE)
        self.assertIsNotNone(window_limit, "Missing consumed-window bound")
        widths = SOURCE.split("for width in [", 1)[1].split("] {", 1)[0]
        frontier_limit = re.search(r"reducedHeightFrontier[\s\S]*?\.prefix\((\d+)\)", SOURCE)
        self.assertIsNotNone(frontier_limit, "Missing frontier-frame bound")
        self.assertLessEqual(int(window_limit[1]) * len(widths.split(",")) * (1 + int(frontier_limit[1])), 612)

    def test_straddling_peers_do_not_consume_slots_with_negative_rectangles(self):
        renderer = (OVERLAY / "NativeTranslationRenderer.swift").read_text()
        validity = renderer.split("static func valid(_ rect: CGRect)", 1)[1].split("\n    }", 1)[0]
        valid_width = re.search(r"rect\.(size\.)?width > 0", validity)
        valid_height = re.search(r"rect\.(size\.)?height > 0", validity)
        gate_width = re.search(r"contact\.(size\.)?width > inset \* 2", SOURCE)
        gate_height = re.search(r"contact\.(size\.)?height > inset \* 2", SOURCE)
        for comparison in (valid_width, valid_height, gate_width, gate_height):
            self.assertIsNotNone(comparison, "Production dimension filter changed; adapt evaluator")

        def dimension(contact, comparison, name):
            return getattr(contact.size if comparison[1] else contact, name)

        panel = rect(0, 0, 100, 100)
        # Ink already includes the caller's output-pixel guard. All intersect.
        for ink in (rect(-12, 30, 40, 20), rect(30, -12, 20, 40),
                    rect(72, 30, 40, 20), rect(30, 72, 20, 40)):
            with self.subTest(ink=(ink.minX, ink.minY, ink.width, ink.height)):
                for contact in contact_rectangles(panel, ink):
                    # Read whether production checks raw size or standardized
                    # getters, so switching to raw dimensions fixes this test.
                    if (dimension(contact, valid_width, "width") > 0
                            and dimension(contact, valid_height, "height") > 0
                            and dimension(contact, gate_width, "width") > 2
                            and dimension(contact, gate_height, "height") > 2):
                        self.assertGreater(contact.size.width, 0, "Negative width consumes a contact slot")
                        self.assertGreater(contact.size.height, 0, "Negative height consumes a contact slot")
                        self.assertGreaterEqual(contact.minX, panel.minX)
                        self.assertGreaterEqual(contact.minY, panel.minY)
                        self.assertLessEqual(contact.maxX, panel.maxX)
                        self.assertLessEqual(contact.maxY, panel.maxY)


if __name__ == "__main__":
    unittest.main()
