# SPDX-License-Identifier: MIT
# Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * A terminal spinner that animates in its own `spawn`ed task.
 *
 * `startSpinner` returns a handle immediately. The other verbs send commands
 * over the handle's channel: `spawn` deep-copies its scope at launch, so the
 * channel is the only state the caller and the task share.
 *
 * Off a terminal nothing is drawn, but the task still runs and accepts
 * commands, so calling code needs no branch.
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

/** Commands that may be queued before a sender blocks. */
def const QUEUE as int init 32;

/** Stream name for standard output. */
export def const STDOUT as string init "stdout";
/** Stream name for standard error, the default. */
export def const STDERR as string init "stderr";

/**
 * How a spinner looks and where it writes. Build one with `options`.
 * @field name {string} catalogue name; unknown or "" falls back to `dots`
 * @field speed {int} frame interval in ms; 0 or less uses the animation's own
 * @field label {string} initial status text
 * @field stream {string} `STDOUT` or `STDERR`; anything else means `STDERR`
 */
export def struct Options {
    name as string,
    speed as int,
    label as string,
    stream as string
};

/**
 * Handle to a running spinner.
 * @field commands {channel of Command} command queue the task reads
 * @field worker {task of int} animating task; yields the frame count
 * @field options {Options} resolved options last sent to the task
 */
export def struct Spinner {
    commands as channel of Command,
    worker as task of int,
    options as Options
};

/**
 * One instruction to a running spinner.
 * @field kind {string} "stop", "status" or "update"; other kinds are ignored
 * @field text {string} new status text, for "status"
 * @field options {Options} new options, for "update"
 */
export def struct Command {
    kind as string,
    text as string,
    options as Options
};

# esc is the escape character, built from its code point because an escape byte
# in source is invisible in a diff.
func esc() {
    return convert.fromCodepoint(27);
}

/** Terminal width assumed when the real one cannot be read. */
export def const FALLBACK_COLS as int init 80;

/** Terminal height assumed when the real one cannot be read. */
export def const FALLBACK_ROWS as int init 24;

/**
 * Control sequence that erases the current line and moves the cursor to its
 * start.
 * @return {string} `\r` then `ESC[2K`
 */
export func eraseLine() {
    return "\r" + esc() + "[2K";
}

/**
 * Control sequence that erases the last `rows` lines and leaves the cursor at
 * the start of the topmost one. For one row it equals `eraseLine()`; each
 * further row adds a cursor-up (`ESC[A`) and another erase.
 * @param rows {int} lines the last block occupied; below 1 counts as 1
 * @return {string} erase sequence
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
 * Split a frame on `\n`.
 * @param frame {string} frame text
 * @return {list of string} lines, in order; one for a single-row frame
 */
export func frameRows(frame as string) {
    return strings.split($frame, "\n");
}

/**
 * Terminal width in columns. Returns `FALLBACK_COLS` (80) when `term.size`
 * throws (not a terminal, stubbed `term`) or reports zero (an unsized
 * pseudo-terminal).
 * @param stream {string} `STDOUT` or `STDERR`
 * @return {int} columns, at least 1
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
 * Terminal height in rows, or `FALLBACK_ROWS` (24) when it cannot be read.
 * @param stream {string} `STDOUT` or `STDERR`
 * @return {int} rows, at least 1
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
 * Rows a spinner may draw: `wanted`, capped at the terminal height minus one.
 * A taller block would scroll the terminal, and the cursor-up erase cannot
 * reach rows that scrolled off the top.
 * @param stream {string} `STDOUT` or `STDERR`
 * @param wanted {int} animation height
 * @return {int} rows to draw, at least 1
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
 * Keep the first `maxRows` rows of a frame. Rows are dropped, not scaled.
 * @param frame {string} frame text
 * @param maxRows {int} most rows to keep; below 1 keeps the whole frame
 * @return {string} clipped frame
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
 * Trim text to `budget` runes, ending a cut text with `…` (counted in the
 * budget). Runes, not display columns: the interpreter has no character-width
 * table, so wide characters can still overflow.
 * @param status {string} text to fit
 * @param budget {int} runes available
 * @return {string} the text, the trimmed text, or "" when `budget` is below 1
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
# character when the line already fills its width. fitStatus would leave an
# exactly-full line alone; here the line fits but what followed it did not.
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
 * Break text into chunks of at most `width` runes, cutting mid-word. A status
 * box is a fixed shape: a word-aware wrap leaves ragged gaps and fails on a word
 * longer than the box.
 * @param text {string} text to break
 * @param width {int} most runes per chunk
 * @return {list of string} chunks; `[""]` for empty text, `[]` when `width` < 1
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
 * Lay a status out in at most `rows` lines of at most `width` runes. Its `\n`
 * breaks are kept, long lines are cut with `wrapHard`, and when text is left
 * over the last line ends in `…`.
 * @param status {string} message, may contain `\n`
 * @param rows {int} spinner height, the most lines the message may use
 * @param width {int} runes available to the right of the spinner
 * @return {list of string} lines; empty for blank text or a budget below 1
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
 * Compose a frame and its status into the block to write, exactly as tall as
 * the frame and, unless the frame alone is wider, at most `width - 1` runes
 * wide, so it does not wrap. The status
 * starts beside the first row and gets `width - frameCols - 2` runes per row
 * (one separating space, the last column left empty); see `layoutStatus`. The
 * frame is never cut.
 *
 * The last column stays empty because a line ending at the edge leaves the
 * cursor in the pending-wrap state, and terminals disagree on what the next
 * newline does.
 * @param frame {string} current frame
 * @param status {string} text beside it, may contain `\n`
 * @param frameCols {int} measured frame width, from the catalogue
 * @param width {int} terminal width
 * @return {string} block to write, rows joined with "\n"
 */
export func renderBlock(frame as string, status as string, frameCols as int, width as int) {
    def rows as list of string init frameRows($frame);
    def lines as list of string init layoutStatus($status, len($rows), $width - $frameCols - 2);
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
 * Control sequence that hides the cursor.
 * @return {string} `ESC[?25l`
 */
export func hideCursor() {
    return esc() + "[?25l";
}

/**
 * Control sequence that shows the cursor. Every path that hides it must write
 * this, including failure paths.
 * @return {string} `ESC[?25h`
 */
export func showCursor() {
    return esc() + "[?25h";
}

/**
 * Options with speed 0 and stream `STDERR`. Use this instead of a struct
 * literal: the struct will gain fields, this call will not.
 * @param name {string} catalogue name, or "" for the default
 * @param label {string} initial status text
 * @return {Options} options for `startSpinner` or `updateSpinner`
 */
export func options(name as string, label as string) {
    return Options{name: $name, speed: 0, label: $label, stream: STDERR};
}

/**
 * Normalise options: an unknown or empty name becomes `frames.DEFAULT_NAME`,
 * any stream but `STDOUT` becomes `STDERR`, a negative speed becomes 0.
 * @param opts {Options} options as supplied
 * @return {Options} resolved options
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
 * Frame interval: `opts.speed` when positive, else the animation's own.
 * @param opts {Options} resolved options
 * @return {int} interval in milliseconds
 */
export func intervalOf(opts as Options) {
    if ($opts.speed > 0) {
        return $opts.speed;
    }
    return frames.get($opts.name).interval;
}

/**
 * Join a frame and its status with one space, with no width limit or erase
 * sequence. A blank status gives the frame alone. The task draws with
 * `renderBlock`.
 * @param frame {string} current frame
 * @param status {string} text beside it, "" for none
 * @return {string} the line
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
 * Whether a stream is a terminal. `startSpinner` checks this once; when false
 * the spinner writes nothing.
 * @param stream {string} `STDOUT` or `STDERR`
 * @return {bool} true for a terminal
 */
export func drawable(stream as string) {
    return os.isTerminal($stream);
}

/**
 * State of the animating task. It changes only through the pure functions
 * `applyCommand`, `drewRows` and `advance`, so tests can drive it without a
 * terminal.
 * @field options {Options} options in force
 * @field spec {frames.Frames} animation the options select
 * @field status {string} text beside the spinner
 * @field index {int} next frame to draw, not wrapped
 * @field drawn {int} frames written
 * @field rows {int} lines the block on screen occupies, for the next erase
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
 * Initial state: frame 0, nothing drawn, status set to the label, `rows` 1.
 * @param opts {Options} resolved options
 * @return {State} initial state
 */
export func newState(opts as Options) {
    return State{
        options: $opts,
        spec: frames.get($opts.name),
        status: $opts.label,
        index: 0,
        drawn: 0,
        # One, not the animation's height: nothing is on screen yet, and a
        # taller first erase would wipe what the program printed before.
        rows: 1,
        stopped: false
    };
}

/**
 * Apply one command. "stop" only sets `stopped`. "status" replaces the status.
 * "update" resolves the new options, switches the animation, sets the status to
 * the new label and restarts at frame 0. Unknown kinds change nothing.
 * @param st {State} state before the command
 * @param c {Command} command to apply
 * @return {State} state after it
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
 * Record the rows just written, so the next erase undoes exactly those. It is
 * tracked, not recomputed, because after an update the screen still shows the
 * previous animation's height.
 * @param st {State} state that just drew
 * @param rows {int} rows written
 * @return {State} state with `rows` set
 */
export func drewRows(st as State, rows as int) {
    def out as State init $st;
    $out.rows = $rows;
    return $out;
}

/**
 * Frame to draw next: `index` modulo the frame count.
 * @param st {State} current state
 * @return {string} frame text
 */
export func currentFrame(st as State) {
    return $st.spec.frames[$st.index % len($st.spec.frames)];
}

/**
 * Move to the next frame, incrementing `drawn` only when `counted`.
 * @param st {State} current state
 * @param counted {bool} whether a frame was written
 * @return {State} advanced state
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
 * Launch the animating task and return at once. Whether to draw is decided
 * here, from `drawable` on the resolved stream, and not re-checked later.
 *
 * Pass the handle to `removeSpinner` or `finishSpinner`: until then the task
 * runs and, on a terminal, the cursor stays hidden.
 * @param opts {Options} see `options`
 * @return {Spinner} handle for the other verbs
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
                def fits as int init visibleRows($st.options.stream, $st.spec.rows);
                def block as string init renderBlock(
                    clipFrame(currentFrame($st), $fits),
                    $st.status,
                    $st.spec.cols,
                    terminalWidth($st.options.stream));
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
    return Spinner{commands: $cmds, worker: $worker, options: $o};
}

/**
 * Replace a running spinner's options and restart at frame 0. The status is
 * reset to `opts.label`. A stream change does not re-check `drawable`.
 * @param sp {Spinner} running spinner
 * @param opts {Options} complete new options, not a partial update
 * @return {Spinner} handle with `options` updated; use it from now on
 * @throws {Error} kind "runtime" when the spinner was already removed
 */
export func updateSpinner(sp as Spinner, opts as Options) {
    def o as Options init resolveOptions($opts);
    channel.send($sp.commands, Command{kind: CMD_UPDATE, text: "", options: $o});
    def out as Spinner init $sp;
    $out.options = $o;
    return $out;
}

/**
 * Replace the status text.
 * @param sp {Spinner} running spinner
 * @param msg {string} new status; "" leaves the spinner bare
 * @return {Spinner} the same handle
 * @throws {Error} kind "runtime" when the spinner was already removed
 */
export func statusSpinner(sp as Spinner, msg as string) {
    channel.send($sp.commands, Command{kind: CMD_STATUS, text: $msg, options: $sp.options});
    return $sp;
}

/**
 * Stop a spinner, erase its block and show the cursor. Blocks until the task
 * has finished, then closes the command channel, so nothing is written after it
 * returns.
 * @param sp {Spinner} spinner to stop
 * @return {int} frames drawn; 0 off a terminal
 * @throws {Error} kind "runtime" when the spinner was already removed
 */
export func removeSpinner(sp as Spinner) {
    channel.send($sp.commands, Command{kind: CMD_STOP, text: "", options: $sp.options});
    def drawn as int init task.wait($sp.worker);
    channel.close($sp.commands);
    return $drawn;
}

/**
 * `removeSpinner`, then write `mark msg` and a newline to the spinner's stream,
 * cut to the terminal width like a status. Writes this line even off a
 * terminal; writes nothing when both are blank.
 * @param sp {Spinner} spinner to stop
 * @param mark {string} leading symbol, such as a check mark; "" for none
 * @param msg {string} line to leave behind
 * @return {int} frames drawn; 0 off a terminal
 * @throws {Error} kind "runtime" when the spinner was already removed
 */
export func finishSpinner(sp as Spinner, mark as string, msg as string) {
    def drawn as int init removeSpinner($sp);
    def line as string init renderBlock($mark, $msg, len($mark), terminalWidth($sp.options.stream));
    if (strings.trim($line) == "") {
        return $drawn;
    }
    writeTo($sp.options.stream, $line + "\n");
    return $drawn;
}

/**
 * Room an animation needs.
 * @field cols {int} terminal columns every frame occupies
 * @field rows {int} lines every frame occupies
 */
export def struct Size {
    cols as int,
    rows as int
};

/**
 * Measured size of an animation, in terminal columns, not runes: an emoji is
 * one rune and two columns.
 * @param name {string} catalogue name; unknown falls back to `dots`
 * @return {Size} columns and rows
 */
export func spinnerSize(name as string) {
    def spec as frames.Frames init frames.get($name);
    return Size{cols: $spec.cols, rows: $spec.rows};
}

/**
 * All catalogue names, for a `--spinner` flag's help or a picker.
 * @return {list of string} names, sorted
 */
export func spinnerNames() {
    return frames.names();
}
