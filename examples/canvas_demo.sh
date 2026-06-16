#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# canvas_demo.sh - two independently scrollable, boxed panels in a partial
# viewport. The flagship canvas showcase + integration stress test.
#
# Each panel is a draw.sh BOX (decoration, drawn in viewport coords) wrapping a
# CANVAS (src/canvas.sh) that holds the scrollable content. The content list is
# far taller than the canvas, and every line is drawn at its scrolled row —
# rows outside the canvas are CLIPPED by the canvas, so one panel's overflow can
# never spill into the other panel or the status line. This is what the viewport
# alone cannot do: an interior, 4-edge-clipped sub-region with local coordinates.
#
# Integrates: canvas (clipped regions) + draw.sh box (decoration) +
# tuish_str_window (per-line horizontal slice) + tuish_clamp_scroll (keep the
# selected row visible) + tuish_viewport fixed (partial area).
#
# Tab switches the focused panel; up/down (or j/k) move the selection and
# scroll; left/right pan horizontally; q or Ctrl-W quits.

set -euf

_dir="$(cd "$(dirname "$0")" && pwd)"
_src="${_dir}/../src"
. "${_src}/compat.sh"
. "${_src}/ord.sh"
. "${_src}/tui.sh"
. "${_src}/term.sh"
. "${_src}/canvas.sh"
. "${_src}/event.sh"
. "${_src}/hid.sh"
. "${_src}/viewport.sh"
. "${_src}/str.sh"
. "${_src}/draw.sh"
. "${_src}/keybind.sh"

# Layout (viewport-relative). Two 20x8 boxes side by side, content 18x6 inside.
NLINES=24
BOX_R=2 BOX_W=20 BOX_H=8
IN_W=$(( BOX_W - 2 )) IN_H=$(( BOX_H - 2 ))
P0_C=2 P1_C=24

# Per-panel state: scroll top (0-based), selected line, horizontal pan.
_focus=0
_help=0
_top_0=0 _sel_0=0 _h_0=0
_top_1=0 _sel_1=0 _h_1=0

_pad2 () { if test "$1" -lt 10; then _p2="0$1"; else _p2="$1"; fi; }

# Content line for panel $1, index $2 -> _lt. Left lines are short; right lines
# overflow the panel width so the horizontal slice (str_window) is exercised.
_line_text ()
{
	_pad2 "$2"
	if test "$1" -eq 0
	then _lt="L${_p2} item ${_p2}"
	else _lt="R${_p2} a fairly long row END${_p2}"
	fi
}

_render_panel ()   # $1 panel  $2 box-col  $3 top  $4 sel  $5 hoff
{
	local _p=$1 _bc=$2 _top=$3 _sel=$4 _h=$5
	local _style=light
	test "$_focus" -eq "$_p" && _style=heavy

	# Box frame + title in viewport coords (canvas OFF).
	tuish_canvas_off
	tuish_draw_box "$BOX_R" "$_bc" "$BOX_W" "$BOX_H" style="$_style"
	if test "$_p" -eq 0
	then tuish_print_at "$BOX_R" "$(( _bc + 2 ))" " LEFT "
	else tuish_print_at "$BOX_R" "$(( _bc + 2 ))" " RIGHT "
	fi

	# Scrollable content in a clipped canvas inset by the border.
	tuish_canvas $(( BOX_R + 1 )) $(( _bc + 1 )) "$IN_W" "$IN_H"
	local _i=0 _crow _t _hl
	while test "$_i" -lt "$NLINES"
	do
		_crow=$(( _i - _top + 1 ))      # canvas row; clipped if <1 or >IN_H
		_line_text "$_p" "$_i"; _t="$_lt"
		tuish_str_window _t "$_h" "$IN_W"
		_hl=0
		test "$_i" -eq "$_sel" && test "$_crow" -ge 1 && test "$_crow" -le "$IN_H" && _hl=1
		test "$_hl" -eq 1 && tuish_sgr 7
		tuish_print_at "$_crow" 1 "$TUISH_SWINDOW"
		test "$_hl" -eq 1 && tuish_sgr_reset
		_i=$(( _i + 1 ))
	done
	tuish_canvas_off
}

_render ()
{
	tuish_hide_cursor
	tuish_canvas_off
	tuish_clear_region 1 1 "$TUISH_VIEW_COLS" "$TUISH_VIEW_ROWS"
	tuish_print_at 1 1 "canvas demo — Tab: focus  ↑↓/jk: scroll  ←→: pan  q: quit"
	_render_panel 0 "$P0_C" "$_top_0" "$_sel_0" "$_h_0"
	_render_panel 1 "$P1_C" "$_top_1" "$_sel_1" "$_h_1"
	tuish_canvas_off
	local _fl=LEFT
	test "$_focus" -eq 1 && _fl=RIGHT
	tuish_print_at $(( BOX_R + BOX_H )) 1 "focus: $_fl   ?: help   (clipped rows never leak between panels)"

	# A centered modal overlay, drawn last so it sits opaque OVER the panels.
	if test "$_help" -eq 1
	then
		tuish_canvas_off
		tuish_overlay \
			"canvas demo — keys" \
			"" \
			"Tab    switch panel" \
			"up/dn  scroll + select" \
			"lt/rt  pan horizontally" \
			"?      toggle this help" \
			"q      quit"
	fi
	tuish_flush
}

# Move the focused panel's selection by $1; keep it visible via clamp_scroll.
_panel_move ()   # $1 delta
{
	local _s _t
	eval "_s=\$_sel_$_focus _t=\$_top_$_focus"
	_s=$(( _s + $1 ))
	test "$_s" -lt 0 && _s=0
	test "$_s" -gt $(( NLINES - 1 )) && _s=$(( NLINES - 1 ))
	tuish_clamp_scroll "$_s" "$_t" "$IN_H"
	_t=$TUISH_SCROLL
	eval "_sel_$_focus=$_s _top_$_focus=$_t"
	tuish_request_redraw
}

_pan ()   # $1 delta
{
	local _h
	eval "_h=\$_h_$_focus"
	_h=$(( _h + $1 ))
	test "$_h" -lt 0 && _h=0
	eval "_h_$_focus=$_h"
	tuish_request_redraw
}

_toggle ()      { _focus=$(( 1 - _focus )); tuish_request_redraw; }
_toggle_help () { _help=$(( 1 - _help )); tuish_request_redraw; }
_q ()           { tuish_quit_clear; return 0; }

tuish_on_redraw () { _render; }

tuish_bind 'tab'     '_toggle'
tuish_bind 'up'      '_panel_move -1'
tuish_bind 'char k'  '_panel_move -1'
tuish_bind 'down'    '_panel_move 1'
tuish_bind 'char j'  '_panel_move 1'
tuish_bind 'left'    '_pan -1'
tuish_bind 'right'   '_pan 1'
tuish_bind 'char ?'  '_toggle_help'
tuish_bind 'ctrl-w'  '_q'
tuish_bind 'char q'  '_q'
tuish_bind 'resize'  'tuish_request_redraw'
tuish_bind '*'       ':'

tuish_init
tuish_viewport fixed $(( BOX_R + BOX_H ))
_render
tuish_run || :
tuish_fini
