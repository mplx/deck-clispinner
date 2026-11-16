<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Design

## Scope

The deck draws a terminal spinner while a program does slow work:
`startSpinner` launches the animation in its own task and returns a handle at
once, `statusSpinner` and `updateSpinner` change the text and the animation,
and `removeSpinner` / `finishSpinner` stop it, erase it and restore the
cursor. The catalogue holds 91 animations (`spinnerNames`, `spinnerSize`).

It deliberately is not:

- **A progress bar.** There is no percentage, count or rate; the status text
  is free, so a caller writes `"12 of 40"` itself.
- **Several spinners at once.** Each spinner erases the rows it drew last;
  two on one stream would erase each other.
- **Colour.** Frames and status are written as given; a caller that wants
  colour puts the escape sequences in the status text. (The deck roadmap in
  `jennifer` describes the deck as colourable through `ansi`; the code has no
  colour support.)
- **An app.** It has a scoped name and no `bin`; `demo.j` sits outside
  `src/` so it is never vendored.

## Decisions

- **The animation runs in a `spawn`ed task.** The caller's slow work then
  needs no hooks or callbacks. `spawn` copies its scope at launch, so the
  task never sees later writes to the caller's variables; a command channel
  in the handle is the only shared state. Every verb takes the handle for
  that reason, and the channel holds 32 commands before a sender waits.
- **A pure state machine inside the task.** `newState`, `applyCommand`,
  `drewRows`, `advance`, `currentFrame` and `renderBlock` are pure functions
  over `State`, so the whole animation logic is tested without a terminal or
  a task.
- **Off a terminal it draws nothing, but still runs.** `startSpinner` checks
  `os.isTerminal` once, on the chosen stream. When piped or redirected
  nothing is written, yet the task accepts commands as usual, so calling code
  needs no branch. `updateSpinner` does not repeat the check.
- **Standard error by default.** A spinner is decoration; writing it to
  stderr keeps a program's stdout clean for its real output. `STDOUT` is
  opt-in.
- **Forgiving options.** An unknown or empty animation name falls back to
  `dots` (so user input can be passed through), any stream but `STDOUT` means
  `STDERR`, and a negative speed means the animation's own interval. Options
  are built with `options(name, label)` so that new fields do not break
  callers.
- **The block never wraps.** A redraw erases only the rows the last block
  occupied, so a wrapped row would stay on screen. The frame is never cut;
  the status gets as many rows as the animation is tall, is broken mid-word
  and cut with `…`; the terminal's last column stays empty (terminals
  disagree on the pending-wrap state); an animation taller than the window
  is clipped to its height minus one, since the cursor-up erase cannot reach
  rows that scrolled off. Width and height are read on every frame, with
  80 by 24 (`FALLBACK_COLS`, `FALLBACK_ROWS`) when they cannot be read.
- **Measured sizes.** `len` counts runes, not terminal columns, so each
  animation carries its size in columns and rows, and frames are padded to
  it so the status column does not move.
- **Animations from cli-spinners.** 90 animations are ported from the
  `cli-spinners` npm package (MIT), so `dots` or `line` look the way users
  expect; `src/frames.j` is generated from its `spinners.json`. One is the
  deck's own: `soccerVertical`, the only multi-row animation.
- **MIT licence**, matching the animation data it carries. The deck is not
  on the shared deck CI layer.

## Errors

The deck throws nothing of its own. Sending to a removed spinner fails in
`channel` with a `"closed"` error, since `removeSpinner` closes the channel
after the task has finished; that is a programming error, not a condition to
handle. Reading the terminal size never throws (the fallback applies).

## Security and limits

- The deck writes only control sequences it builds itself (erase line,
  cursor up, hide and show cursor) plus the frame and the caller's status.
  A status from elsewhere is written as is; strip control characters from
  untrusted text before showing it.
- The command queue is bounded (32); a sender waits rather than queueing
  without end.
- A running spinner keeps the cursor hidden; a program must call
  `removeSpinner` or `finishSpinner`, also on its error paths.

## Testing and validation

`src/clispinner_test.j` covers the API and the state machine through its
pure functions (commands, frame advance, drawn-row tracking, layout of
multi-row statuses, cutting and clipping), and the task through a command
round trip, off a terminal, so nothing is drawn. `src/frames_test.j` checks
the catalogue (sorted names, the default and the fallback, `has`, every
animation usable, the one multi-row animation). Drawing on a real
terminal is checked by hand with `demo.j` (the tour, `multiline` and
`names`). There is no CI gate in this repository; the tests and
`jennifer lint src/*.j demo.j` are run by hand.

## Known limitations and open questions

- Status width is counted in runes, so wide characters (CJK, most emoji) in
  a status can still overflow and wrap.
- A stream change in `updateSpinner` is not re-checked for being a terminal.
- `frames.has` validates a name, but is reached only through `src/frames.j`,
  not the entry module.

## Dependencies on the interpreter

- The floor is `>=0.26.0`. The deck needs `time.fromMilliseconds`, `spawn`,
  and `channel.len` for the non-blocking command poll.
- `term.size` and `os.isTerminal`. No capability is required; on
  `jennifer-tiny` `term` is a stub, the size falls back, and `os.isTerminal`
  reports false, so the spinner draws nothing.
- Bundled modules only; no `[decks]` dependencies.
