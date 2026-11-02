# SPDX-License-Identifier: MIT
# Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for frames.j: the spinner catalogue.
# Run with:
#
#     jennifer test src/frames_test.j
#
# The overlay is spliced over frames.j, so the module's own names are reachable
# bare (CATALOGUE, get, names).

use testing;
use strings;

func testCatalogueIsNotEmpty() {
    testing.assertTrue(len(names()) > 50);
}

func testNamesAreSorted() {
    def n as list of string init names();
    def i as int init 1;
    while ($i < len($n)) {
        testing.assertTrue($n[$i - 1] < $n[$i]);
        $i = $i + 1;
    }
}

func testTheDefaultIsInTheCatalogue() {
    testing.assertTrue(has(DEFAULT_NAME));
}

func testGetReturnsTheNamedSpinner() {
    def f as Frames init get("line");
    testing.assertEqual($f.name, "line");
    testing.assertEqual(len($f.frames), 4);
    testing.assertEqual($f.frames[0], "-");
}

func testABackslashFrameSurvivedThePort() {
    # `line` is the one animation whose data contains a backslash, so it is the
    # canary for the escaping in the generated source.
    def f as Frames init get("line");
    testing.assertEqual($f.frames[1], "\\");
    testing.assertEqual(len($f.frames[1]), 1);
}

func testAnUnknownNameFallsBackRatherThanThrowing() {
    def f as Frames init get("no-such-spinner");
    testing.assertEqual($f.name, DEFAULT_NAME);
}

func testHasDistinguishesKnownFromUnknown() {
    testing.assertTrue(has("dots"));
    testing.assertFalse(has("no-such-spinner"));
}

func testEverySpinnerIsUsable() {
    # A spinner with no frames or a non-positive interval would divide by zero
    # or spin the CPU, so the whole catalogue is checked rather than a sample.
    for (def n in names()) {
        def f as Frames init get($n);
        testing.assertEqual($f.name, $n);
        testing.assertTrue(len($f.frames) > 0);
        testing.assertTrue($f.interval > 0);
        testing.assertTrue($f.cols > 0);
        testing.assertTrue($f.rows > 0);
        checkFrameHeights($f);
    }
}

# checkFrameHeights asserts every frame of an animation is the height the
# animation declares. The renderer erases exactly `rows` lines before redrawing,
# so a frame taller than that would leave its extra rows on screen, and a
# shorter one would erase into whatever was printed above the spinner.
func checkFrameHeights(f as Frames) {
    for (def fr in $f.frames) {
        testing.assertEqual(len(strings.split($fr, "\n")), $f.rows);
    }
}

func testTheVerticalSoccerSpinnerIsTheMultiRowOne() {
    # Derived here rather than taken from upstream, which ships nothing taller
    # than one row, so that multi-row rendering has something to render.
    def f as Frames init get("soccerVertical");
    testing.assertEqual($f.rows, 12);
    testing.assertEqual($f.cols, 2);
    testing.assertEqual(len($f.frames), len(get("soccerHeader").frames));
}
