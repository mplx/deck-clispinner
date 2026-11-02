#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.25.0
#
# Hand-run demo; needs a terminal. It lives outside `src/`, so it is never
# vendored.
#
#     ./demo.j            the tour
#     ./demo.j multiline  the multi-row spinner and its status block
#     ./demo.j names      list every spinner name

use io;
use os;
use strings;
use time;

import "./src/clispinner.j" as spinner;

func pause(ms as int) {
    time.sleep(time.fromMilliseconds($ms));
}

func tour() {
    def sp as spinner.Spinner init spinner.startSpinner(
        spinner.options("dots", "resolving the dependency graph"));
    pause(1200);

    $sp = spinner.statusSpinner($sp, "fetching @acme/demo 0.1.0");
    pause(1200);

    $sp = spinner.statusSpinner($sp, "verifying checksums");
    pause(1000);

    def fast as spinner.Options init spinner.options("shark", "vendoring");
    $fast.speed = 40;
    $sp = spinner.updateSpinner($sp, $fast);
    pause(2500);

    $sp = spinner.updateSpinner($sp, spinner.options("earth", "writing the lockfile"));
    pause(1500);

    def drawn as int init spinner.finishSpinner($sp, "ok", "installed 3 decks");
    io.printf("drew %d frames\n", $drawn);
}

func multiline() {
    # soccerVertical is 2 columns by 12 rows, so the status gets twelve rows.
    # Text past the twelfth is cut: the erase only undoes twelve rows.
    io.printf("a line printed before the spinner, which must survive\n");

    def o as spinner.Options init spinner.options(
        "soccerVertical",
        "a status message with room to breathe");
    $o.stream = spinner.STDOUT;
    def sp as spinner.Spinner init spinner.startSpinner($o);
    pause(1600);

    # Explicit line breaks, honoured up to the spinner's height.
    $sp = spinner.statusSpinner($sp, "resolving\n  @acme/alpha\n  @acme/beta\n  @acme/gamma");
    pause(1600);

    # Far more text than twelve short rows can hold: it is hard cut.
    $sp = spinner.statusSpinner($sp, strings.repeat("overflowing text ", 40));
    pause(1600);

    def drawn as int init spinner.finishSpinner($sp, "ok", "the block is gone");
    io.printf("drew %d frames\n", $drawn);
    def sz as spinner.Size init spinner.spinnerSize("soccerVertical");
    io.printf("soccerVertical is %d cols x %d rows\n", $sz.cols, $sz.rows);
}

func showNames() {
    def names as list of string init spinner.spinnerNames();
    io.printf("%d spinners:\n", len($names));
    for (def n in $names) {
        io.printf("  %s\n", $n);
    }
}

if (len(os.ARGS) > 1 and os.ARGS[1] == "names") {
    showNames();
} elseif (len(os.ARGS) > 1 and os.ARGS[1] == "multiline") {
    multiline();
} else {
    tour();
}
