# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Load guard: skip re-definition if already sourced (see tui.sh).
if test -n "${_tuish_canvas_loaded:-}"; then return 0; fi
_tuish_canvas_loaded=1
# src/canvas.sh - Canvas: a bounded drawing surface within the viewport
# Optional module. Source after term.sh.
#
# A canvas is a rectangular sub-region of the viewport with its own local,
# 1-based CELL coordinate system: canvas-local (1,1) is the canvas top-left.
# While a canvas is active, tuish_vmove — and therefore every positioned
# primitive built on it (tuish_print_at, draw.sh ops, ...) — translates
# canvas-local coordinates onto the screen and clips to the canvas bounds on
# all four edges. A cell may span CW x CH terminal columns/rows, so a canvas
# with CW=2 addresses a grid of 2-wide glyphs (e.g. emoji) with plain 1..W
# column indices. The canvas composes with the viewport the way the viewport
# composes with the terminal — one level down.
#
# Provides:
#   tuish_canvas R C W H [CW] [CH] - define + activate a canvas
#   tuish_canvas_off               - deactivate (back to plain viewport coords)
#   tuish_canvas_clear             - clear the canvas interior (spaces)
#
# Variables (set by tuish_canvas):
#   TUISH_CANVAS        - 1 while a canvas is active, 0 otherwise
#   TUISH_CANVAS_W/H    - canvas size in cells
#   TUISH_CANVAS_CW/CH  - cell size in terminal columns/rows
#
# Dependencies: term.sh (tuish_clear_region) and a viewport (TUISH_VIEW_TOP).
# The _tuish_canvas_* state and TUISH_CANVAS* defaults live in tui.sh so
# tuish_vmove's canvas branch stays inert when this module is not sourced.

# tuish_canvas R C W H [CW] [CH]
# R C: canvas top-left in viewport-relative coords (1-based). W H: canvas size
# in cells. CW CH: terminal columns/rows per cell (default 1x1). Activates it.
tuish_canvas ()
{
	_tuish_canvas_r=$1
	_tuish_canvas_c=$2
	_tuish_canvas_cw=${5:-1}
	_tuish_canvas_ch=${6:-1}
	TUISH_CANVAS_W=$3
	TUISH_CANVAS_H=$4
	TUISH_CANVAS_CW=$_tuish_canvas_cw
	TUISH_CANVAS_CH=$_tuish_canvas_ch
	# Precompute the origin so vmove only ever ADDS it (never multiplies by it):
	#   abs_row  = row0 + (LR-1)*CH + 1   (folds in TUISH_VIEW_TOP)
	#   term_col = col0 + (LC-1)*CW + 1   (columns are not viewport-translated)
	_tuish_canvas_row0=$(( TUISH_VIEW_TOP + $1 - 2 ))
	_tuish_canvas_col0=$(( $2 - 1 ))
	_tuish_canvas_on=1
	TUISH_CANVAS=1
}

# Deactivate the canvas; subsequent moves use plain viewport coordinates.
tuish_canvas_off ()
{
	_tuish_canvas_on=0
	TUISH_CANVAS=0
}

# Clear the canvas interior to spaces — the canvas-aware alternative to
# tuish_clear_screen. Fills W*CW by H*CH terminal cells, leaving everything
# outside the canvas (and the rest of the screen) untouched.
tuish_canvas_clear ()
{
	local _cc_w=$(( TUISH_CANVAS_W * _tuish_canvas_cw ))
	local _cc_h=$(( TUISH_CANVAS_H * _tuish_canvas_ch ))
	local _cc_save=$_tuish_canvas_on
	# Clear in plain viewport coords (canvas off) so the region is not re-scaled.
	# The canvas top-left R,C are already viewport-relative, so use them directly.
	_tuish_canvas_on=0
	tuish_clear_region "$_tuish_canvas_r" "$_tuish_canvas_c" "$_cc_w" "$_cc_h"
	_tuish_canvas_on=$_cc_save
}
