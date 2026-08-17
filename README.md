# @mplx/deck-clispinner

A terminal spinner that animates on its own goroutine, so the caller can get on
with the slow work the spinner is covering.

```jennifer
import "@mplx/deck-clispinner/" as spinner;

def sp as spinner.Spinner init spinner.startSpinner(
    spinner.options("dots", "resolving the dependency graph"));

$sp = spinner.statusSpinner($sp, "fetching @acme/demo 0.1.0");
$sp = spinner.updateSpinner($sp, spinner.options("bouncingBar", "vendoring"));

spinner.finishSpinner($sp, "ok", "installed 3 decks");
```

## The four verbs

| Call | Does |
| ---- | ---- |
| `startSpinner(opts)` | launch the animation and return a handle, immediately |
| `updateSpinner(sp, opts)` | change the animation, speed, label, or stream |
| `statusSpinner(sp, msg)` | change the text shown to the right of the spinner |
| `removeSpinner(sp)` | erase the line, restore the cursor, stop the task |

`finishSpinner(sp, mark, msg)` is `removeSpinner` plus a final line that stays on
screen, which is what most callers actually want at the end.

Every verb takes the handle, because the handle carries the channel. `spawn`
deep-copies its enclosing scope at launch, so the animating task cannot see a
later write to a variable the caller holds; a channel is the one handle that
stays shared, and so it is the only way to talk to a running spinner.

## Options

```jennifer
def o as spinner.Options init spinner.options("dots", "working");
$o.speed = 40;                    # ms per frame; 0 uses the animation's own
$o.stream = spinner.STDOUT;       # default is STDERR
```

`options(name, label)` is the intended constructor: the struct will gain fields,
that call will not. An unknown spinner name falls back to `dots` rather than
throwing, so user input can be passed straight through; use
`frames.has(name)` if you would rather validate it.

`spinner.spinnerNames()` lists all 90 names, which is what a `--spinner` flag's
help text wants, and `spinner.spinnerSize(name)` gives the room one needs.

## Off a terminal it draws nothing

Piped or redirected output stays clean, because a spinner writes control
characters rather than text. The task still runs and still accepts commands, so
calling code needs no branch and tests need no special case. `removeSpinner`
returns the number of frames drawn, which is `0` off a terminal.

## Size, and why it is baked in

Each animation carries the size of the box it draws in:

```jennifer
def sz as spinner.Size init spinner.spinnerSize("material");
# sz.cols == 20, sz.rows == 1
```

This is measured data, not something computed at run time, because a terminal
cell count is not derivable from the string: `len` counts runes, and a rune is
not a column. `moon` is one emoji plus a space, which is two runes and three
columns. Getting that wrong is not cosmetic. A line longer than the terminal
wraps onto a second row, and a redraw erases only the row the cursor is on, so
the spill stays on screen and the spinner appears to scroll. The renderer uses
`cols` with the terminal's own width to trim the status instead, marking the cut
with an ellipsis, and never cuts the frame: a cut status is untidy, a cut frame
is a broken animation.

## The status fills the rows the spinner leaves

A status message gets as many rows as the animation is tall, and no more:

```jennifer
spinner.statusSpinner($sp, "resolving\n  @acme/alpha\n  @acme/beta");
```

Its own line breaks are honoured within that budget, so a message can be shaped
beside a tall spinner. Past the last row it is **hard cut** with an ellipsis,
never wrapped on into the terminal: the erase undoes exactly the animation's
height, so a block that grew taller than that would leave rows behind and the
spinner would scroll up the screen. Long text is broken mid-word rather than at
spaces, because a status box is a fixed shape, not prose, and a word-aware wrap
leaves ragged gaps or fails outright on a word longer than the box.

A one-row spinner therefore behaves as it always did: one line, truncated to
fit.

`soccerVertical` is the multi-row one, 2 columns by 12 rows: `soccerHeader`
turned on its side. Upstream ships nothing taller than one row, so without it
there is nothing to exercise multi-row rendering with. See it with
`./demo.j multiline`.

## It fits the window, in both directions

Two things are read from the terminal on every frame, and both are limits the
block is held inside.

**Width.** The last column is deliberately left empty. A line written right to
the edge leaves the cursor in the pending-wrap state, and terminals disagree
about what the next newline does: some move down a row, some wrap and then move
down, which quietly makes the block a row taller than the erase is about to
undo. One spare column removes the disagreement.

**Height.** An animation taller than the window is the one case the erase cannot
undo. Drawing it scrolls the terminal, and once a row has scrolled off the top,
moving the cursor up stops at the first line instead of reaching it, so the
erase undoes the wrong rows and the block is stranded on screen. A tall spinner
is therefore clipped to what the window holds, one row held back for the cursor.
`soccerVertical` in a nine-row window draws eight rows of itself; shrink the
window further and it keeps working.

## The animations

All 90 come from [cli-spinners](https://github.com/sindresorhus/cli-spinners)
(MIT), which is the set every terminal spinner uses, so `dots` or `line`
animates the way a user already expects. `src/frames.j` is pure data; the
rendering and the concurrency live in `src/clispinner.j`.

## Installing it

```toml
[decks]
"@jennifer/clispinner" = "^0.1.0"
```

`jvc install` vendors it to `vendor/jennifer/clispinner/`, and the interpreter's
own vendor resolver finds it from the scoped name, so the import is
`import "@jennifer/clispinner/"` and not a path into `vendor/`.

## Development

```sh
jennifer test src/clispinner_test.j    # the API and the state machine
jennifer test src/frames_test.j        # the catalogue
jennifer lint src/*.j                  # must stay at zero
./demo.j                               # watch it run; needs a terminal
./demo.j names                         # list every spinner
```

The tests run off a terminal, where the spinner deliberately draws nothing. The
state machine is exercised through its pure functions (`applyCommand`,
`advance`, `currentFrame`, `renderLine`) and the concurrency through the command
round trip, so the suite is safe to run anywhere.

`src/frames.j` is generated from the upstream `spinners.json`. Regenerate it
rather than hand-editing it.
