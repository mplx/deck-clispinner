# @mplx/clispinner

[![release](https://img.shields.io/github/v/release/mplx/deck-clispinner)](https://github.com/mplx/deck-clispinner/releases/latest)

A terminal spinner for Jennifer. The animation runs in its own `spawn`ed task,
so the caller carries on with the slow work while it spins.

```toml
[decks]
"@mplx/clispinner" = "^0.1.0"
```

`jvc install` vendors it to `vendor/mplx/clispinner/`. Import it by its scoped
name, not by a path into `vendor/`:

```jennifer
import "@mplx/clispinner/" as spinner;

def sp as spinner.Spinner init spinner.startSpinner(
    spinner.options("dots", "resolving the dependency graph"));

$sp = spinner.statusSpinner($sp, "fetching @acme/demo 0.1.0");
$sp = spinner.updateSpinner($sp, spinner.options("bouncingBar", "vendoring"));

spinner.finishSpinner($sp, "ok", "installed 3 decks");
```

## API

| Call | Does |
| ---- | ---- |
| `startSpinner(opts)` | launch the animation; returns a handle immediately |
| `updateSpinner(sp, opts)` | replace animation, speed, label and stream; restarts the frame index |
| `statusSpinner(sp, msg)` | replace the text to the right of the spinner |
| `removeSpinner(sp)` | stop the task, erase the block, restore the cursor; returns frames drawn |
| `finishSpinner(sp, mark, msg)` | `removeSpinner`, then print `mark msg` as a line that stays |
| `options(name, label)` | an `Options` with defaults filled in |
| `spinnerNames()` | all 91 animation names, sorted |
| `spinnerSize(name)` | the animation's `Size` (`cols`, `rows`) |

Every verb takes the handle because the handle carries the command channel.
`spawn` deep-copies its scope at launch, so the task never sees later writes to
the caller's variables; the channel is the only shared state. `removeSpinner`
blocks until the task has finished and closes the channel, so sending to a
removed spinner throws a `runtime` error. Always call `removeSpinner` or
`finishSpinner`: a running spinner keeps the cursor hidden.

## Options

```jennifer
def o as spinner.Options init spinner.options("dots", "working");
$o.speed = 40;                    # ms per frame; 0 uses the animation's own
$o.stream = spinner.STDOUT;       # default spinner.STDERR
```

Build options with `options(name, label)`: the struct will gain fields, the
call will not. An unknown or empty name falls back to `dots` instead of
throwing, so user input can be passed through; `has(name)` in `src/frames.j`
validates it. Any stream other than `STDOUT` becomes `STDERR`, and a negative
speed becomes 0.

## Off a terminal it draws nothing

Whether the stream is a terminal is checked once, at `startSpinner`. Off a
terminal (piped, redirected) nothing is written, but the task still runs and
accepts commands, so calling code needs no branch. `removeSpinner` then
returns `0`. Changing the stream with `updateSpinner` does not repeat the
check.

## Layout

Each animation carries its measured size, because `len` counts runes, not
terminal columns: `moon` is one emoji plus a space, 2 runes and 3 columns.
`material` is 20 columns by 1 row.

The block never wraps, because a redraw erases only the rows the last block
occupied and a wrapped row would stay on screen:

- The frame is never cut. The status is cut, with an ellipsis (`…`).
- The status gets as many rows as the animation is tall. Its own `\n` breaks
  are honoured within that budget; long lines are broken mid-word; text past
  the last row is dropped and the cut marked with `…`.
- The terminal's last column stays empty. A line ending at the edge leaves the
  cursor in the pending-wrap state, and terminals disagree on what the next
  newline does.
- An animation taller than the window is clipped to the window height minus
  one row (`soccerVertical` in a nine-row window draws eight rows). Without
  this the terminal scrolls and the erase cannot reach the top rows.

Width and height are read on every frame. When they cannot be read the
spinner assumes 80 columns by 24 rows (`FALLBACK_COLS`, `FALLBACK_ROWS`).
Status width is counted in runes, so wide characters in a status can still
overflow.

```jennifer
spinner.statusSpinner($sp, "resolving\n  @acme/alpha\n  @acme/beta");
```

## The animations

90 animations are ported from
[cli-spinners](https://github.com/sindresorhus/cli-spinners) (MIT), so `dots`
or `line` looks the way users expect. Frames are padded to the animation's
width so the status column does not move. `soccerVertical` (2 columns by 12
rows) is this deck's own: `soccerHeader` turned on its side, the only
multi-row animation. `src/frames.j` is generated from upstream's
`spinners.json`; regenerate it instead of editing it by hand.

## Development

```sh
jennifer test src/clispinner_test.j    # API and state machine
jennifer test src/frames_test.j        # the catalogue
jennifer lint src/*.j demo.j           # must stay clean
./demo.j                               # the tour; needs a terminal
./demo.j multiline                     # soccerVertical and a multi-row status
./demo.j names                         # list every spinner
```

The tests run off a terminal, so nothing is drawn. The state machine is tested
through its pure functions (`applyCommand`, `advance`, `currentFrame`,
`renderBlock`) and the task through the command round trip.

## Licence

MIT, see [LICENSE.md](LICENSE.md). Copyright (C) 2026 mplx &lt;mplx@jennifer-lang.dev&gt;.
Animation data from cli-spinners, MIT.
