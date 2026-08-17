# SPDX-License-Identifier: MIT
# Copyright (C) 2026 mplx <developer@mplx.eu>

/**
 * A terminal spinner that animates on its own goroutine.
 *
 * `startSpinner` hands back a handle and returns immediately; the animation
 * runs in a `spawn`ed task while the caller gets on with the slow work that
 * needed a spinner in the first place. Everything after that is a message:
 * `updateSpinner` changes the animation, `statusSpinner` changes the text beside
 * it, `removeSpinner` erases the line and stops the task.
 *
 * **Why messages and not shared state.** `spawn` deep-copies its enclosing scope
 * at launch, so the task cannot see a later write to a variable the caller
 * holds. A channel is the one handle that stays shared, so it is the only way
 * to talk to a running spinner. That is also why every verb here takes the
 * `Spinner` handle: it carries the channel.
 *
 * **Off a terminal it renders nothing.** Piped or redirected output stays clean,
 * which matters because a spinner writes control characters, not text. The task
 * still runs and still accepts commands, so calling code needs no branch.
 * @module clispinner
 * @example
 * import "./clispinner.j" as clispinner;
 * def sp as clispinner.Spinner init clispinner.startSpinner(
 *     clispinner.options("dots", "resolving"));
 * clispinner.statusSpinner($sp, "fetching @acme/demo");
 * clispinner.removeSpinner($sp);
 */

use channel;
use convert;
use io;
use os;
use lists;
use strings;
use task;
use term;
use time;

import "./frames.j" as frames;

/** Stop the animation, erase the line, and let the task return. */
def const CMD_STOP as string init "stop";
/** Replace the text shown beside the spinner. */
def const CMD_STATUS as string init "status";
/** Replace the animation, its speed, or both. */
def const CMD_UPDATE as string init "update";

/** How many commands may be queued before a sender blocks. */
def const QUEUE as int init 32;

/** The stream name for standard output. */
export def const STDOUT as string init "stdout";
/** The stream name for standard error, the usual place for progress output. */
export def const STDERR as string init "stderr";

/**
 * How a spinner should look and behave.
 * @field name {string} a catalogue name from `frames.j`; unknown falls back
 * @field speed {int} the frame interval in milliseconds, or 0 for the spinner's own
 * @field label {string} the text shown to the right of the spinner
 * @field stream {string} `STDOUT` or `STDERR`
 */
export def struct Options {
    name as string,
    speed as int,
    label as string,
    stream as string
};

/**
 * A handle to a running spinner. Carries the command channel, which is the only
 * shared thing between the caller and the animating task.
 * @field commands {channel of Command} the command queue the task reads
 * @field worker {task of int} the animating task, yielding the frame count
 * @field options {Options} the options the spinner was started with
 */
export def struct Spinner {
    commands as channel of Command,
    worker as task of int,
    options as Options
};

/**
 * One instruction to a running spinner.
 * @field kind {string} `CMD_STOP`, `CMD_STATUS`, or `CMD_UPDATE`
 * @field text {string} the new status text, for `CMD_STATUS`
 * @field options {Options} the new options, for `CMD_UPDATE`
 */
export def struct Command {
    kind as string,
    text as string,
    options as Options
};

# esc is the escape character. It is built from its code point rather than
# written as a literal, because an escape byte in source is invisible in a diff
# and does not survive every editor.
func esc() {
    return convert.fromCodepoint(27);
}

/** The terminal width assumed when the real one cannot be read. */
export def const FALLBACK_COLS as int init 80;

/** The terminal height assumed when the real one cannot be read. */
export def const FALLBACK_ROWS as int init 24;

/**
 * The control sequence that erases the current line and returns the cursor to
 * its start, which is what makes the next frame overwrite the last one.
 * @return {string} carriage return followed by the erase-line sequence
 */
export func eraseLine() {
    return "\r" + esc() + "[2K";
}

/**
 * The control sequence that erases the last `rows` lines and leaves the cursor
 * at the start of the topmost one, ready for the block to be redrawn.
 *
 * A one-row block is just `eraseLine`. More than that needs the cursor walked
 * back up, because erase-line only ever erases the line the cursor is on: a
 * block redrawn without this leaves every row but the last on screen, which is
 * the debris a wrapped or multi-row spinner otherwise trails behind it.
 * @param rows {int} how many lines the last block occupied; below 1 counts as 1
 * @return {string} the erase sequence
 */
export func eraseBlock(rows as int) {
    def out as string init eraseLine();
    def i as int init 1;
    while ($i < $rows) {
        $out = $out + esc() + "[A" + eraseLine();
        $i = $i + 1;
    }
    return $out;
}

/**
 * Split a frame into its rows. Every animation in the catalogue today is one
 * row, but the format allows more and the renderer handles it.
 * @param frame {string} the frame text
 * @return {list of string} the frame's lines, in order
 */
export func frameRows(frame as string) {
    return strings.split($frame, "\n");
}

/**
 * The terminal's width in columns, or `FALLBACK_COLS` when it cannot be read.
 *
 * A width of zero comes back from a pseudo-terminal nobody sized, and a stubbed
 * `term` throws; both mean "no idea", and guessing 80 is better than laying out
 * against zero columns.
 * @param stream {string} `STDOUT` or `STDERR`
 * @return {int} the width in columns, always at least 1
 */
export func terminalWidth(stream as string) {
    def cols as int init 0;
    try {
        $cols = term.size($stream).cols;
    } catch (e) {
        $cols = 0;
    }
    if ($cols < 1) {
        return FALLBACK_COLS;
    }
    return $cols;
}

/**
 * The terminal's height in rows, or `FALLBACK_ROWS` when it cannot be read.
 * @param stream {string} `STDOUT` or `STDERR`
 * @return {int} the height in rows, always at least 1
 */
export func terminalHeight(stream as string) {
    def rows as int init 0;
    try {
        $rows = term.size($stream).rows;
    } catch (e) {
        $rows = 0;
    }
    if ($rows < 1) {
        return FALLBACK_ROWS;
    }
    return $rows;
}

/**
 * How many rows a spinner may actually draw in this terminal.
 *
 * An animation taller than the window is the one case the erase cannot undo.
 * Drawing it scrolls the terminal, and once a row has scrolled off the top,
 * moving the cursor up stops at the first line instead of reaching it: the
 * erase then undoes the wrong rows and the block is left on screen. A row is
 * held back for the cursor, so the block never touches the bottom line either.
 * @param stream {string} `STDOUT` or `STDERR`
 * @param wanted {int} the animation's own height
 * @return {int} the height to draw, at least 1 and never taller than the window
 */
export func visibleRows(stream as string, wanted as int) {
    def room as int init terminalHeight($stream) - 1;
    if ($room < 1) {
        return 1;
    }
    if ($wanted > $room) {
        return $room;
    }
    if ($wanted < 1) {
        return 1;
    }
    return $wanted;
}

/**
 * Keep at most `maxRows` rows of a frame, for an animation taller than the
 * terminal. The animation is clipped rather than scaled, because a spinner is
 * art: dropping rows keeps what is left recognisable, where squeezing it would
 * not.
 * @param frame {string} the frame text
 * @param maxRows {int} the most rows to keep
 * @return {string} the frame, clipped to that height
 */
export func clipFrame(frame as string, maxRows as int) {
    def rows as list of string init frameRows($frame);
    if (len($rows) <= $maxRows or $maxRows < 1) {
        return $frame;
    }
    def out as list of string init [];
    def i as int init 0;
    while ($i < $maxRows) {
        $out[] = $rows[$i];
        $i = $i + 1;
    }
    return strings.join($out, "\n");
}

/**
 * Trim status text to a column budget, marking it when something was cut.
 *
 * The budget is counted in runes, not display columns: the frame's own width is
 * known exactly (the catalogue measured it), but arbitrary status text would
 * need a character-width table the interpreter does not have. For the text a
 * status line actually carries this is the same number, and where it is not,
 * erring narrow keeps the line inside the terminal, which is the point.
 * @param status {string} the text to fit
 * @param budget {int} how many columns are left for it
 * @return {string} the text, trimmed to fit, or "" when nothing fits
 */
export func fitStatus(status as string, budget as int) {
    if ($budget < 1) {
        return "";
    }
    if (len($status) <= $budget) {
        return $status;
    }
    if ($budget == 1) {
        return "…";
    }
    return strings.substring($status, 0, $budget - 1) + "…";
}

# markCut ends a line with an ellipsis to show text was dropped, giving up a
# character to make room when the line already fills its width. It cannot defer
# to fitStatus, which leaves an exactly-full line alone: here the line fits but
# what followed it did not, and that is the thing being reported.
func markCut(line as string, width as int) {
    if ($width < 1) {
        return "";
    }
    if (len($line) < $width) {
        return $line + "…";
    }
    return strings.substring($line, 0, $width - 1) + "…";
}

/**
 * Break text into chunks of at most `width` runes, cutting mid-word rather than
 * looking for spaces.
 *
 * A status line is a fixed box beside a spinner, not prose: a word-aware wrap
 * would leave ragged gaps in a two or three row box and can fail outright on a
 * single word longer than the box. A hard cut always fills the space it has.
 * @param text {string} the text to break up
 * @param width {int} the maximum runes per chunk
 * @return {list of string} the chunks; a single empty chunk for empty text
 */
export func wrapHard(text as string, width as int) {
    def out as list of string init [];
    if ($width < 1) {
        return $out;
    }
    if ($text == "") {
        $out[] = "";
        return $out;
    }
    def i as int init 0;
    while ($i < len($text)) {
        def end as int init $i + $width;
        if ($end > len($text)) {
            $end = len($text);
        }
        $out[] = strings.substring($text, $i, $end);
        $i = $end;
    }
    return $out;
}

/**
 * Lay a status message out into the rows a spinner leaves beside it.
 *
 * The message gets as many rows as the animation is tall and no more. Its own
 * line breaks are honoured within that budget, so a caller can shape a two-line
 * message beside a two-row spinner, and anything past the last row is cut hard
 * with an ellipsis rather than wrapping into the terminal and scrolling the
 * animation off the screen. A one-row spinner therefore behaves exactly as
 * before: one line, truncated to fit.
 * @param status {string} the message, which may contain line breaks
 * @param rows {int} how many rows the spinner occupies, and so how many the message may
 * @param width {int} the columns available to the right of the spinner
 * @return {list of string} at most `rows` lines, each at most `width` wide
 */
export func layoutStatus(status as string, rows as int, width as int) {
    def out as list of string init [];
    if ($rows < 1 or $width < 1 or strings.trim($status) == "") {
        return $out;
    }
    def pieces as list of string init [];
    for (def line in strings.split($status, "\n")) {
        $pieces = lists.concat($pieces, wrapHard($line, $width));
    }
    def i as int init 0;
    while ($i < len($pieces) and $i < $rows) {
        $out[] = $pieces[$i];
        $i = $i + 1;
    }
    if (len($pieces) > $rows) {
        $out[$rows - 1] = markCut($out[$rows - 1], $width);
    }
    return $out;
}

/**
 * Compose the block to draw: the frame, and the status beside its first row,
 * kept inside the terminal's width so the line never wraps.
 *
 * Wrapping is what breaks a spinner. A line longer than the terminal spills
 * onto a second row, and the next redraw erases only the row the cursor is on,
 * so the spill stays on screen and the animation appears to scroll. The frame
 * is never cut, because a half-drawn frame is worse than a cut status.
 *
 * The status gets the rows the animation is tall, no more. Every frame in the
 * catalogue is padded to its animation's width, so the status column is fixed.
 *
 * The last column is deliberately left empty. A line written right up to the
 * edge leaves the cursor in the pending-wrap state, and terminals disagree
 * about what a newline does next: some move down one row, some wrap and then
 * move down, which silently makes the block a row taller than the erase is
 * about to undo. Giving up one column costs nothing and removes the
 * disagreement.
 * @param frame {string} the current frame
 * @param status {string} the text to put beside it, which may contain line breaks
 * @param frameCols {int} the frame's measured width, from the catalogue
 * @param width {int} the terminal width to stay inside
 * @return {string} the text to write, with "\n" between rows
 */
export func renderBlock(frame as string, status as string, frameCols as int,
    width as int) {
    def rows as list of string init frameRows($frame);
    def lines as list of string init layoutStatus($status, len($rows),
        $width - $frameCols - 2);
    def out as list of string init [];
    def i as int init 0;
    while ($i < len($rows)) {
        if ($i < len($lines) and not ($lines[$i] == "")) {
            $out[] = $rows[$i] + " " + $lines[$i];
        } else {
            $out[] = $rows[$i];
        }
        $i = $i + 1;
    }
    return strings.join($out, "\n");
}

/**
 * The control sequence that hides the cursor, so it does not blink over the
 * animation.
 * @return {string} the hide-cursor sequence
 */
export func hideCursor() {
    return esc() + "[?25l";
}

/**
 * The control sequence that shows the cursor again. Every path that hides the
 * cursor must run this, including the failure paths.
 * @return {string} the show-cursor sequence
 */
export func showCursor() {
    return esc() + "[?25h";
}

/**
 * Build an options value with the defaults filled in, which is the intended way
 * to construct one: the struct gains fields over time, this call does not.
 * @param name {string} a catalogue name, or "" for the default spinner
 * @param label {string} the text beside the spinner
 * @return {Options} the options, ready for `startSpinner`
 */
export func options(name as string, label as string) {
    return Options{
        name: $name,
        speed: 0,
        label: $label,
        stream: STDERR
    };
}

/**
 * Fill in whatever an options value left unset, so the rest of the module never
 * has to ask whether a field is meaningful.
 * @param opts {Options} the options as the caller supplied them
 * @return {Options} the same options with every field resolved
 */
export func resolveOptions(opts as Options) {
    def out as Options init $opts;
    if ($out.name == "" or not frames.has($out.name)) {
        $out.name = frames.DEFAULT_NAME;
    }
    if (not ($out.stream == STDOUT)) {
        $out.stream = STDERR;
    }
    if ($out.speed < 0) {
        $out.speed = 0;
    }
    return $out;
}

/**
 * The frame interval a spinner will actually run at: the caller's speed when
 * they set one, otherwise the interval the animation was designed for.
 * @param opts {Options} the resolved options
 * @return {int} the interval in milliseconds
 */
export func intervalOf(opts as Options) {
    if ($opts.speed > 0) {
        return $opts.speed;
    }
    return frames.get($opts.name).interval;
}

/**
 * Render one frame of the line, without the erase sequence: the frame, then the
 * status text when there is one. This is the whole of the spinner's appearance,
 * kept separate from the writing so it can be asserted on.
 * @param frame {string} the current animation frame
 * @param status {string} the text beside it ("" for none)
 * @return {string} the line to write
 */
export func renderLine(frame as string, status as string) {
    if (strings.trim($status) == "") {
        return $frame;
    }
    return $frame + " " + $status;
}

# writeTo writes a partial line to the chosen stream, with no newline. io.printf
# flushes per call, so a frame appears as soon as it is written.
func writeTo(stream as string, s as string) {
    if ($stream == STDOUT) {
        io.printf("%s", $s);
    } else {
        io.eprintf("%s", $s);
    }
}

/**
 * Report whether a stream is a terminal, which decides whether a spinner draws
 * at all. Redirected output gets none of the control characters.
 * @param stream {string} `STDOUT` or `STDERR`
 * @return {bool} true when that stream is a terminal
 */
export func drawable(stream as string) {
    return os.isTerminal($stream);
}

/**
 * Everything a running spinner knows. It lives inside the animating task and
 * moves forward only through `applyCommand` and `advance`, which keeps the task
 * body itself flat and leaves the interesting behaviour in pure functions that
 * a test can drive without a terminal.
 * @field options {Options} the options in force
 * @field spec {frames.Frames} the animation the options select
 * @field status {string} the text beside the spinner
 * @field index {int} the next frame to draw
 * @field drawn {int} how many frames have been written
 * @field rows {int} how many lines the block on screen occupies, for the erase
 * @field stopped {bool} whether a stop command has arrived
 */
export def struct State {
    options as Options,
    spec as frames.Frames,
    status as string,
    index as int,
    drawn as int,
    rows as int,
    stopped as bool
};

/**
 * The starting state for a set of options.
 * @param opts {Options} the resolved options
 * @return {State} a state ready to draw its first frame
 */
export func newState(opts as Options) {
    return State{
        options: $opts,
        spec: frames.get($opts.name),
        status: $opts.label,
        index: 0,
        drawn: 0,
        # One, not the animation's height: this counts the rows *on screen*, and
        # nothing has been drawn yet. Seeding it from the animation would make a
        # multi-row spinner's first erase walk the cursor up over whatever the
        # program printed before the spinner started.
        rows: 1,
        stopped: false
    };
}

/**
 * Apply one command to a state. A stop only sets the flag: the task decides
 * what to write on the way out, because only it knows whether it drew anything.
 * An update restarts the frame index, since a frame number means nothing to a
 * different animation.
 * @param st {State} the state before the command
 * @param c {Command} the command to apply
 * @return {State} the state after it
 */
export func applyCommand(st as State, c as Command) {
    def out as State init $st;
    if ($c.kind == CMD_STOP) {
        $out.stopped = true;
        return $out;
    }
    if ($c.kind == CMD_STATUS) {
        $out.status = $c.text;
        return $out;
    }
    if ($c.kind == CMD_UPDATE) {
        $out.options = resolveOptions($c.options);
        $out.spec = frames.get($out.options.name);
        $out.status = $out.options.label;
        $out.index = 0;
    }
    return $out;
}

/**
 * Record how many rows the block just written occupies, so the next redraw
 * erases exactly that many. It is tracked rather than recomputed because the
 * erase has to undo what is *on screen*, which is the previous animation's
 * height, not the one that replaced it.
 * @param st {State} the state that just drew
 * @param rows {int} the number of rows written
 * @return {State} the state with its row count updated
 */
export func drewRows(st as State, rows as int) {
    def out as State init $st;
    $out.rows = $rows;
    return $out;
}

/**
 * The frame a state is about to draw, wrapping round the animation.
 * @param st {State} the current state
 * @return {string} the frame text
 */
export func currentFrame(st as State) {
    return $st.spec.frames[$st.index % len($st.spec.frames)];
}

/**
 * Move a state on by one frame, counting the frame as drawn.
 * @param st {State} the current state
 * @param counted {bool} whether a frame was actually written
 * @return {State} the state advanced by one
 */
export func advance(st as State, counted as bool) {
    def out as State init $st;
    if ($counted) {
        $out.drawn = $out.drawn + 1;
    }
    $out.index = $out.index + 1;
    return $out;
}

/**
 * Start a spinner. Returns as soon as the animating task is launched, so the
 * caller can get on with the work the spinner is covering.
 *
 * The returned handle must reach `removeSpinner`, which is what stops the task
 * and puts the cursor back. A spinner left running holds the terminal in a
 * state the user did not ask for.
 * @param opts {Options} how the spinner should look; see `options`
 * @return {Spinner} the handle, for the other verbs in this module
 */
export func startSpinner(opts as Options) {
    def o as Options init resolveOptions($opts);
    def cmds as channel of Command init channel.make(QUEUE);
    def draw as bool init drawable($o.stream);
    def worker as task of int init spawn {
        def st as State init newState($o);
        if ($draw) {
            writeTo($st.options.stream, hideCursor());
        }
        while (not $st.stopped) {
            while (channel.len($cmds) > 0) {
                $st = applyCommand($st, channel.recv($cmds));
            }
            if ($st.stopped) {
                continue;
            }
            if ($draw) {
                def fits as int init visibleRows($st.options.stream,
                    $st.spec.rows);
                def block as string init renderBlock(
                    clipFrame(currentFrame($st), $fits), $st.status,
                    $st.spec.cols, terminalWidth($st.options.stream));
                writeTo($st.options.stream, eraseBlock($st.rows) + $block);
                $st = drewRows($st, len(frameRows($block)));
            }
            $st = advance($st, $draw);
            time.sleep(time.fromMilliseconds(intervalOf($st.options)));
        }
        if ($draw) {
            writeTo($st.options.stream, eraseBlock($st.rows) + showCursor());
        }
        return $st.drawn;
    };
    return Spinner{ commands: $cmds, worker: $worker, options: $o };
}

/**
 * Change a running spinner's animation, speed, label, or stream. The frame
 * index restarts, because a frame number means nothing to a different animation.
 * @param sp {Spinner} the running spinner
 * @param opts {Options} the new options, complete rather than partial
 * @return {Spinner} the handle with its recorded options updated
 */
export func updateSpinner(sp as Spinner, opts as Options) {
    def o as Options init resolveOptions($opts);
    channel.send($sp.commands, Command{
        kind: CMD_UPDATE,
        text: "",
        options: $o
    });
    def out as Spinner init $sp;
    $out.options = $o;
    return $out;
}

/**
 * Set the text shown to the right of the spinner, the usual way to say what the
 * slow thing is currently doing.
 * @param sp {Spinner} the running spinner
 * @param msg {string} the new status text; "" leaves the spinner bare
 * @return {Spinner} the handle, unchanged, so calls can be chained
 */
export func statusSpinner(sp as Spinner, msg as string) {
    channel.send($sp.commands, Command{
        kind: CMD_STATUS,
        text: $msg,
        options: $sp.options
    });
    return $sp;
}

/**
 * Stop a spinner, erase its line, and restore the cursor. Blocks until the task
 * has actually finished, so nothing writes to the terminal after this returns
 * and the caller can print normally again.
 * @param sp {Spinner} the spinner to stop
 * @return {int} how many frames it drew, which is 0 off a terminal
 */
export func removeSpinner(sp as Spinner) {
    channel.send($sp.commands, Command{
        kind: CMD_STOP,
        text: "",
        options: $sp.options
    });
    def drawn as int init task.wait($sp.worker);
    channel.close($sp.commands);
    return $drawn;
}

/**
 * Stop a spinner and print a final line in its place, for the common ending
 * where the work is done and the result should stay on screen.
 * @param sp {Spinner} the spinner to stop
 * @param mark {string} a leading symbol, such as a check mark ("" for none)
 * @param msg {string} the line to leave behind
 * @return {int} how many frames the spinner drew
 */
export func finishSpinner(sp as Spinner, mark as string, msg as string) {
    def drawn as int init removeSpinner($sp);
    def line as string init renderBlock($mark, $msg, len($mark),
        terminalWidth($sp.options.stream));
    if (strings.trim($line) == "") {
        return $drawn;
    }
    writeTo($sp.options.stream, $line + "\n");
    return $drawn;
}

/**
 * How much room an animation needs.
 * @field cols {int} terminal columns the widest frame occupies
 * @field rows {int} lines a frame occupies
 */
export def struct Size {
    cols as int,
    rows as int
};

/**
 * The size of a named animation, for a caller laying out around the spinner:
 * reserving a column for it, or deciding a status will not fit beside it.
 *
 * This is measured data, not a rune count. `len` on a frame counts runes, and
 * an emoji frame is one rune wide and two columns wide.
 * @param name {string} the catalogue name; unknown falls back like `get`
 * @return {Size} the columns and rows the animation occupies
 */
export func spinnerSize(name as string) {
    def spec as frames.Frames init frames.get($name);
    return Size{ cols: $spec.cols, rows: $spec.rows };
}

/**
 * Every spinner name the catalogue knows, for a `--spinner` flag's help text or
 * a picker.
 * @return {list of string} the names, sorted
 */
export func spinnerNames() {
    return frames.names();
}
