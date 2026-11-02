# SPDX-License-Identifier: MIT
# Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for clispinner.j: the spinner API and its animating task.
# Run with:
#
#     jennifer test src/clispinner_test.j
#
# The overlay is spliced over clispinner.j, so the module's own names are bare
# (startSpinner, State) and its import is reached through its alias
# (frames.Frames).
#
# The tests run off a terminal, where the spinner deliberately draws nothing.
# That is what makes them safe to run in a suite: the state machine is exercised
# through the pure functions, and the concurrency through the command round trip.

use testing;
use channel;
use strings;
use time;

# --- options ----------------------------------------------------------------

func testOptionsFillsInTheDefaults() {
    def o as Options init options("dots", "working");
    testing.assertEqual($o.name, "dots");
    testing.assertEqual($o.label, "working");
    testing.assertEqual($o.speed, 0);
    testing.assertEqual($o.stream, STDERR);
}

func testResolveOptionsReplacesAnUnknownSpinner() {
    def o as Options init resolveOptions(options("no-such-spinner", ""));
    testing.assertEqual($o.name, frames.DEFAULT_NAME);
}

func testResolveOptionsReplacesAnEmptyName() {
    def o as Options init resolveOptions(options("", ""));
    testing.assertEqual($o.name, frames.DEFAULT_NAME);
}

func testResolveOptionsKeepsAKnownSpinner() {
    def o as Options init resolveOptions(options("bouncingBar", ""));
    testing.assertEqual($o.name, "bouncingBar");
}

func testResolveOptionsRejectsANegativeSpeed() {
    def o as Options init options("dots", "");
    $o.speed = -5;
    testing.assertEqual(resolveOptions($o).speed, 0);
}

func testResolveOptionsDefaultsAnUnknownStreamToStderr() {
    def o as Options init options("dots", "");
    $o.stream = "somewhere-else";
    testing.assertEqual(resolveOptions($o).stream, STDERR);
}

func testResolveOptionsKeepsStdout() {
    def o as Options init options("dots", "");
    $o.stream = STDOUT;
    testing.assertEqual(resolveOptions($o).stream, STDOUT);
}

func testIntervalFallsBackToTheAnimationsOwn() {
    def o as Options init resolveOptions(options("line", ""));
    testing.assertEqual(intervalOf($o), frames.get("line").interval);
}

func testAnExplicitSpeedWins() {
    def o as Options init options("line", "");
    $o.speed = 7;
    testing.assertEqual(intervalOf(resolveOptions($o)), 7);
}

# --- what a frame looks like -------------------------------------------------

func testRenderLineJoinsFrameAndStatus() {
    testing.assertEqual(renderLine("*", "working"), "* working");
}

func testRenderLineOmitsAnEmptyStatus() {
    testing.assertEqual(renderLine("*", ""), "*");
    testing.assertEqual(renderLine("*", "   "), "*");
}

func testEraseLineReturnsTheCursorFirst() {
    # The carriage return has to come before the erase, or the frame is written
    # at whatever column the last one ended at.
    def e as string init eraseLine();
    testing.assertTrue(strings.startsWith($e, "\r"));
    testing.assertTrue(strings.endsWith($e, "[2K"));
    testing.assertEqual(len($e), 5);
}

func testTheCursorSequencesArePaired() {
    testing.assertTrue(strings.endsWith(hideCursor(), "[?25l"));
    testing.assertTrue(strings.endsWith(showCursor(), "[?25h"));
    testing.assertFalse(hideCursor() == showCursor());
}

# --- staying inside the terminal ---------------------------------------------

func testFitStatusLeavesShortTextAlone() {
    testing.assertEqual(fitStatus("working", 20), "working");
    testing.assertEqual(fitStatus("working", 7), "working");
}

func testFitStatusTrimsAndMarksTheCut() {
    def s as string init fitStatus("a status message long enough to matter", 10);
    testing.assertEqual(len($s), 10);
    testing.assertTrue(strings.endsWith($s, "…"));
}

func testFitStatusGivesUpWhenNothingFits() {
    testing.assertEqual(fitStatus("anything", 0), "");
    testing.assertEqual(fitStatus("anything", -4), "");
}

func testRenderBlockKeepsTheLineInsideTheTerminal() {
    # This is the wrapping bug: `material` is 20 columns, and a 38-column status
    # beside it needs 59. In a 40-column terminal that spills onto a second row,
    # and the next erase only clears the row the cursor is on.
    def spec as frames.Frames init frames.get("material");
    def line as string init renderBlock(
        $spec.frames[0],
        "a status message long enough to matter",
        $spec.cols,
        40);
    testing.assertTrue(len($line) <= 40);
    testing.assertEqual(len(frameRows($line)), 1);
}

func testRenderBlockNeverCutsTheFrame() {
    # A cut status is untidy; a cut frame is a broken animation.
    def spec as frames.Frames init frames.get("material");
    def line as string init renderBlock($spec.frames[0], "status", $spec.cols, 12);
    testing.assertTrue(strings.startsWith($line, $spec.frames[0]));
}

func testRenderBlockDropsAStatusWithNoRoom() {
    def spec as frames.Frames init frames.get("material");
    testing.assertEqual(renderBlock($spec.frames[0], "status", $spec.cols, 21), $spec.frames[0]);
}

func testRenderBlockPutsTheStatusBesideTheFirstRow() {
    def line as string init renderBlock("ab\ncd", "go", 2, 80);
    testing.assertEqual($line, "ab go\ncd");
    testing.assertEqual(len(frameRows($line)), 2);
}

# --- the status fills the rows the spinner leaves, and no more ---------------

func testWrapHardCutsMidWord() {
    def parts as list of string init wrapHard("abcdefgh", 3);
    testing.assertEqual(len($parts), 3);
    testing.assertEqual($parts[0], "abc");
    testing.assertEqual($parts[2], "gh");
}

func testWrapHardKeepsAnEmptyLineAsARow() {
    # A deliberate blank line in a message is a row the caller asked for.
    testing.assertEqual(len(wrapHard("", 5)), 1);
    testing.assertEqual(wrapHard("", 5)[0], "");
}

func testLayoutStatusUsesEveryRowItIsGiven() {
    def out as list of string init layoutStatus("abcdefghij", 3, 4);
    testing.assertEqual(len($out), 3);
    testing.assertEqual($out[0], "abcd");
    testing.assertEqual($out[1], "efgh");
    testing.assertEqual($out[2], "ij");
}

func testLayoutStatusStopsAtTheRowBudget() {
    # Four rows of text into a two-row spinner: the rest is cut, not wrapped on
    # into the terminal where it would scroll the animation away.
    def out as list of string init layoutStatus("abcdefghij", 2, 3);
    testing.assertEqual(len($out), 2);
    testing.assertTrue(strings.endsWith($out[1], "…"));
}

func testLayoutStatusHonoursItsOwnLineBreaks() {
    def out as list of string init layoutStatus("one\ntwo", 2, 10);
    testing.assertEqual(len($out), 2);
    testing.assertEqual($out[0], "one");
    testing.assertEqual($out[1], "two");
}

func testLineBreaksAreCappedAtTheSpinnerHeight() {
    # Three lines of message beside a two-row spinner: the third is dropped and
    # the cut is marked, because a break past the last row would push the block
    # taller than the erase knows how to undo.
    def out as list of string init layoutStatus("one\ntwo\nthree", 2, 10);
    testing.assertEqual(len($out), 2);
    testing.assertEqual($out[0], "one");
    testing.assertEqual($out[1], "two…");
}

func testAOneRowSpinnerStillGetsOneLine() {
    def out as list of string init layoutStatus("one\ntwo", 1, 10);
    testing.assertEqual(len($out), 1);
    testing.assertEqual($out[0], "one…");
}

func testLayoutStatusOfEmptyTextIsNoRows() {
    testing.assertEqual(len(layoutStatus("", 3, 10)), 0);
    testing.assertEqual(len(layoutStatus("   ", 3, 10)), 0);
    testing.assertEqual(len(layoutStatus("text", 0, 10)), 0);
    testing.assertEqual(len(layoutStatus("text", 3, 0)), 0);
}

func testRenderBlockSpreadsAStatusDownTheBlock() {
    # Six columns, of which the frame takes two and the separator one. The last
    # column is left empty on purpose, so the status gets two: the message fills
    # all three rows of the block.
    def block as string init renderBlock("ab\ncd\nef", "123456", 2, 6);
    testing.assertEqual($block, "ab 12\ncd 34\nef 56");
    testing.assertEqual(len(frameRows($block)), 3);
}

func testNoRowIsWrittenToTheLastColumn() {
    # A line taken right to the edge leaves the cursor in the pending-wrap
    # state, and terminals disagree about what the next newline does. One spare
    # column removes the disagreement.
    def spec as frames.Frames init frames.get("material");
    def block as string init renderBlock(
        $spec.frames[0],
        "a status message long enough to be cut",
        $spec.cols,
        40);
    for (def row in frameRows($block)) {
        testing.assertTrue(len($row) <= 39);
    }
}

func testRenderBlockNeverGrowsTheBlockTallerThanTheFrame() {
    # However long the message, the block stays the animation's height, or the
    # erase would leave rows behind.
    def long as string init "a message far too long to fit beside this spinner";
    def block as string init renderBlock("ab\ncd", $long, 2, 10);
    testing.assertEqual(len(frameRows($block)), 2);
    for (def row in frameRows($block)) {
        testing.assertTrue(len($row) <= 10);
    }
}

# --- an animation taller than the window --------------------------------------

func testClipFrameShortensATallFrame() {
    testing.assertEqual(clipFrame("a\nb\nc\nd", 2), "a\nb");
    testing.assertEqual(len(frameRows(clipFrame("a\nb\nc\nd", 2))), 2);
}

func testClipFrameLeavesAFittingFrameAlone() {
    testing.assertEqual(clipFrame("a\nb", 5), "a\nb");
    testing.assertEqual(clipFrame("a\nb", 2), "a\nb");
}

func testClipFrameNeverReturnsNothing() {
    testing.assertEqual(clipFrame("a\nb", 0), "a\nb");
}

func testVisibleRowsHoldsBackARowForTheCursor() {
    # Off a terminal the fallback height stands in, and one row is reserved.
    testing.assertEqual(visibleRows(STDERR, 4), 4);
    testing.assertEqual(visibleRows(STDERR, FALLBACK_ROWS), FALLBACK_ROWS - 1);
    testing.assertEqual(visibleRows(STDERR, 999), FALLBACK_ROWS - 1);
}

func testVisibleRowsAlwaysAllowsOneRow() {
    testing.assertEqual(visibleRows(STDERR, 0), 1);
    testing.assertEqual(visibleRows(STDERR, -3), 1);
}

func testTerminalHeightFallsBackRatherThanReturningZero() {
    testing.assertEqual(terminalHeight(STDERR), FALLBACK_ROWS);
    testing.assertTrue(terminalHeight(STDERR) >= 1);
}

func testATallSpinnerIsClippedToWhatTheWindowHolds() {
    # The whole reason the clamp exists: soccerVertical is twelve rows, and a
    # window shorter than that would scroll, putting rows out of reach of the
    # cursor-up erase and stranding the block on screen.
    def spec as frames.Frames init frames.get("soccerVertical");
    def fits as int init 5;
    def block as string init renderBlock(
        clipFrame($spec.frames[0], $fits),
        "status",
        $spec.cols,
        40);
    testing.assertEqual(len(frameRows($block)), $fits);
}

func testTheVerticalSoccerSpinnerIsMultiRow() {
    def spec as frames.Frames init frames.get("soccerVertical");
    testing.assertTrue($spec.rows > 1);
    testing.assertEqual(len(frameRows($spec.frames[0])), $spec.rows);
}

func testNoFrameOverflowsItsDeclaredBox() {
    # The layout arithmetic budgets `cols` columns for the frame, so no row may
    # need more. This is asserted in runes, which is the only measure available
    # at run time and is a lower bound on columns: a row within its rune budget
    # can still be wider on screen, which is why the catalogue measures the
    # columns at generation time instead of the renderer guessing here.
    for (def n in frames.names()) {
        def spec as frames.Frames init frames.get($n);
        for (def f in $spec.frames) {
            checkRowsFitTheBox(frameRows($f), $spec.cols);
        }
    }
}

# checkRowsFitTheBox is the inner assertion of testNoFrameOverflowsItsDeclaredBox,
# split out to keep the loop nesting inside the linter's limit.
func checkRowsFitTheBox(rows as list of string, cols as int) {
    for (def row in $rows) {
        testing.assertTrue(len($row) <= $cols);
    }
}

func testEraseBlockOfOneRowIsJustAnEraseLine() {
    testing.assertEqual(eraseBlock(1), eraseLine());
    testing.assertEqual(eraseBlock(0), eraseLine());
}

func testEraseBlockWalksTheCursorUp() {
    # Three rows means erase, up, erase, up, erase: the cursor has to end on the
    # topmost row or the redraw starts in the wrong place.
    def e as string init eraseBlock(3);
    testing.assertEqual(len(strings.split($e, "[2K")) - 1, 3);
    testing.assertEqual(len(strings.split($e, "[A")) - 1, 2);
    testing.assertTrue(strings.endsWith($e, "[2K"));
}

func testFrameRowsSplitsAMultiRowFrame() {
    testing.assertEqual(len(frameRows("one")), 1);
    testing.assertEqual(len(frameRows("one\ntwo\nthree")), 3);
}

func testTerminalWidthFallsBackRatherThanReturningZero() {
    # Off a terminal there is no width to read, and laying out against zero
    # columns would drop every status.
    testing.assertTrue(terminalWidth(STDERR) >= 1);
    testing.assertEqual(terminalWidth(STDERR), FALLBACK_COLS);
}

func testSpinnerSizeReportsMeasuredColumns() {
    def s as Size init spinnerSize("material");
    testing.assertEqual($s.cols, 20);
    testing.assertEqual($s.rows, 1);
}

func testAnEmojiFrameIsWiderThanItsRuneCount() {
    # The reason the catalogue carries `cols` at all: `moon` is one emoji plus a
    # space, which is two runes and three columns.
    def spec as frames.Frames init frames.get("moon");
    testing.assertEqual(len($spec.frames[0]), 2);
    testing.assertEqual($spec.cols, 3);
}

func testEverySpinnerHasASize() {
    for (def n in frames.names()) {
        def s as Size init spinnerSize($n);
        testing.assertTrue($s.cols > 0);
        testing.assertTrue($s.rows > 0);
    }
}

# --- the state machine -------------------------------------------------------

func testAFreshStateErasesOnlyTheCurrentLine() {
    # Nothing has been drawn yet, so the first erase must not walk the cursor up
    # over output the program printed before the spinner started.
    def st as State init newState(resolveOptions(options("line", "")));
    testing.assertEqual($st.rows, 1);
    testing.assertEqual(eraseBlock($st.rows), eraseLine());
}

func testDrewRowsRecordsWhatIsOnScreen() {
    def st as State init newState(resolveOptions(options("line", "")));
    testing.assertEqual(drewRows($st, 3).rows, 3);
}

func testNewStateStartsAtTheFirstFrame() {
    def st as State init newState(resolveOptions(options("line", "hi")));
    testing.assertEqual($st.index, 0);
    testing.assertEqual($st.drawn, 0);
    testing.assertEqual($st.status, "hi");
    testing.assertFalse($st.stopped);
    testing.assertEqual(currentFrame($st), "-");
}

func testTheFrameIndexWrapsRound() {
    def st as State init newState(resolveOptions(options("line", "")));
    def n as int init len($st.spec.frames);
    def i as int init 0;
    def first as string init currentFrame($st);
    while ($i < $n) {
        $st = advance($st, true);
        $i = $i + 1;
    }
    testing.assertEqual($st.index, $n);
    testing.assertEqual(currentFrame($st), $first);
}

func testAdvanceCountsOnlyDrawnFrames() {
    def st as State init newState(resolveOptions(options("line", "")));
    $st = advance($st, false);
    testing.assertEqual($st.index, 1);
    testing.assertEqual($st.drawn, 0);
    $st = advance($st, true);
    testing.assertEqual($st.index, 2);
    testing.assertEqual($st.drawn, 1);
}

func testAStatusCommandChangesOnlyTheText() {
    def st as State init newState(resolveOptions(options("line", "before")));
    $st = advance($st, true);
    def after as State init applyCommand(
        $st,
        Command{kind: CMD_STATUS, text: "after", options: $st.options});
    testing.assertEqual($after.status, "after");
    testing.assertEqual($after.index, $st.index);
    testing.assertEqual($after.options.name, "line");
}

func testAnUpdateCommandRestartsTheAnimation() {
    def st as State init newState(resolveOptions(options("line", "one")));
    $st = advance($st, true);
    $st = advance($st, true);
    def next as Options init resolveOptions(options("bouncingBar", "two"));
    def after as State init applyCommand($st, Command{kind: CMD_UPDATE, text: "", options: $next});
    testing.assertEqual($after.options.name, "bouncingBar");
    testing.assertEqual($after.spec.name, "bouncingBar");
    testing.assertEqual($after.status, "two");
    testing.assertEqual($after.index, 0);
}

func testAStopCommandOnlySetsTheFlag() {
    def st as State init newState(resolveOptions(options("line", "x")));
    $st = advance($st, true);
    def after as State init applyCommand(
        $st,
        Command{kind: CMD_STOP, text: "", options: $st.options});
    testing.assertTrue($after.stopped);
    testing.assertEqual($after.drawn, $st.drawn);
}

func testAnUnknownCommandIsIgnored() {
    def st as State init newState(resolveOptions(options("line", "x")));
    def after as State init applyCommand(
        $st,
        Command{kind: "nonsense", text: "ignored", options: $st.options});
    testing.assertEqual($after.status, "x");
    testing.assertFalse($after.stopped);
}

# --- the running task --------------------------------------------------------

func testASpinnerStartsAndStops() {
    def sp as Spinner init startSpinner(options("dots", "working"));
    def drawn as int init removeSpinner($sp);
    # Off a terminal nothing is drawn, which is the point of the check.
    testing.assertEqual($drawn, 0);
}

func testTheHandleCarriesResolvedOptions() {
    def sp as Spinner init startSpinner(options("no-such-spinner", "x"));
    testing.assertEqual($sp.options.name, frames.DEFAULT_NAME);
    removeSpinner($sp);
}

func testCommandsReachARunningSpinner() {
    # The round trip is the thing under test: a spinner that never drained its
    # queue would leave these commands sitting in the channel.
    def o as Options init options("dots", "start");
    $o.speed = 5;
    def sp as Spinner init startSpinner($o);
    $sp = statusSpinner($sp, "middle");
    $sp = updateSpinner($sp, options("line", "end"));
    time.sleep(time.fromMilliseconds(60));
    testing.assertEqual(channel.len($sp.commands), 0);
    testing.assertEqual($sp.options.name, "line");
    removeSpinner($sp);
}

func testUpdateReturnsAHandleWithTheNewOptions() {
    def sp as Spinner init startSpinner(options("dots", "a"));
    def next as Spinner init updateSpinner($sp, options("star", "b"));
    testing.assertEqual($next.options.name, "star");
    testing.assertEqual($next.options.label, "b");
    removeSpinner($next);
}

func testStatusLeavesTheHandleAlone() {
    def sp as Spinner init startSpinner(options("dots", "a"));
    def same as Spinner init statusSpinner($sp, "b");
    testing.assertEqual($same.options.name, $sp.options.name);
    removeSpinner($same);
}

func testRemoveClosesTheCommandChannel() {
    testing.assertThrows("sendAfterRemove", "runtime");
}

# sendAfterRemove is the throwing call testRemoveClosesTheCommandChannel asserts
# on: talking to a spinner that has already been removed is a mistake worth
# hearing about, not a silent no-op.
func sendAfterRemove() {
    def sp as Spinner init startSpinner(options("dots", ""));
    removeSpinner($sp);
    channel.send($sp.commands, Command{kind: CMD_STATUS, text: "too late", options: $sp.options});
}

func testManySpinnersRunIndependently() {
    def a as Spinner init startSpinner(options("dots", "a"));
    def b as Spinner init startSpinner(options("line", "b"));
    $a = statusSpinner($a, "still a");
    testing.assertEqual($a.options.name, "dots");
    testing.assertEqual($b.options.name, "line");
    removeSpinner($a);
    removeSpinner($b);
}

func testSpinnerNamesComeFromTheCatalogue() {
    testing.assertEqual(len(spinnerNames()), len(frames.names()));
}

func testDrawableIsFalseOffATerminal() {
    # The suite runs off a terminal, which is what keeps every other test here
    # from writing control characters.
    testing.assertFalse(drawable(STDERR));
}

func testFinishSpinnerReportsTheFramesDrawn() {
    # An empty mark and message leave nothing to print, so this writes nothing.
    def sp as Spinner init startSpinner(options("dots", "working"));
    testing.assertEqual(finishSpinner($sp, "", ""), 0);
}

func testFinishSpinnerStopsTheSpinner() {
    testing.assertThrows("sendAfterFinish", "runtime");
}

# sendAfterFinish is the throwing call testFinishSpinnerStopsTheSpinner asserts
# on: finishSpinner removes the spinner, which closes its command channel.
func sendAfterFinish() {
    def sp as Spinner init startSpinner(options("dots", ""));
    finishSpinner($sp, "", "");
    channel.send($sp.commands, Command{kind: CMD_STATUS, text: "too late", options: $sp.options});
}
