#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# cooperative.sh — one tuish loop driving TWO live apps at once.
#
# A single host event loop drives two mounted child contexts side by side, in one
# fork-free process, with NO nested tuish_run: a ticking CLOCK on the left and the
# interactive text EDITOR (examples/editor.sh) on the right. This is the cooperative,
# non-modal counterpart to the modal hosting in test_hosting.sh — here the host keeps
# its loop and feeds each event to the right child (tuish_ctx_dispatch), so both
# widgets stay live simultaneously: type in the editor while the clock keeps ticking.
#
#   Input model — mouse routes by region (whichever box it is over); the keyboard
#   goes to the editor; idle ticks BOTH children; Ctrl+W quits the host.
#
# The children are ordinary examples: the editor is unchanged and does not know it is
# hosted; the clock is a tiny inline widget written the same way an example would be.

# ─── Bootstrap ────────────────────────────────────────────────────
# Runs top-level (a host), but guard like the examples so it could itself be hosted
# one day: only bring up modules when tuish is not already loaded.
if test -z "${_tuish_tui_loaded:-}"
then
	_coop_standalone=1
	set -euf
	_coop_dir="$(cd "$(dirname "$0")" && pwd)"
	_src="${_coop_dir}/../src"
	. "${_src}/compat.sh"
	. "${_src}/ord.sh"
	. "${_src}/tui.sh"
	. "${_src}/term.sh"
	. "${_src}/event.sh"
	. "${_src}/hid.sh"
	. "${_src}/viewport.sh"
	. "${_src}/str.sh"
	. "${_src}/buf.sh"
	. "${_src}/draw.sh"
	. "${_src}/keybind.sh"
	_coop_ex="${_coop_dir}"
else
	_coop_standalone=0
	_coop_ex="${TUISH_EXAMPLES:-.}"
fi

# The editor, SOURCED (tuish is loaded, so it only defines its _ed_* functions,
# including _ed_setup — the non-blocking half of _ed_main we drive here).
. "${_coop_ex}/editor.sh"

# ─── Palette ──────────────────────────────────────────────────────
C_BG='13:17:23'
C_BORDER='40:52:74'
C_ACCENT='125:211:222'
C_ACCENT2='181:160:255'
C_DIM='120:132:150'
C_HEAD='236:240:248'

# ─── Clock widget ─────────────────────────────────────────────────
# A minimal hostable widget: register a render handler by name, fill its region, and
# re-render on every idle tick so the time stays live. It never calls tuish_run — it
# is designed to be driven by a host, exactly like an example's _setup half.
_clk_render ()
{
	tuish_draw_fill 1 1 "$TUISH_VIEW_COLS" "$TUISH_VIEW_ROWS" bg=$C_BG
	local _t; _t="$(date '+%H:%M:%S')"
	tuish_str_width _t; local _tw=$TUISH_SWIDTH
	local _row=$(( (TUISH_VIEW_ROWS + 1) / 2 ))
	local _col=$(( (TUISH_VIEW_COLS - _tw) / 2 + 1 ))
	test $_col -lt 1 && _col=1
	tuish_text $(( _row - 1 )) "$_col" "$_t" fg=$C_ACCENT bg=$C_BG
	local _lbl='live · idle-driven'
	tuish_str_width _lbl; local _lw=$TUISH_SWIDTH
	local _lc=$(( (TUISH_VIEW_COLS - _lw) / 2 + 1 ))
	test $_lc -lt 1 && _lc=1
	tuish_text $(( _row + 1 )) "$_lc" "$_lbl" fg=$C_DIM bg=$C_BG
}

_clk_setup ()
{
	tuish_init
	tuish_on_redraw _clk_render
	# Re-render each idle tick so the seconds advance without any input.
	tuish_bind 'idle'   'tuish_request_redraw'
	tuish_bind 'resize' 'tuish_request_redraw'
	tuish_bind '*'      ':'
	tuish_viewport fullscreen     # hosted → fills our region (no alt-screen)
	_clk_render
}

# ─── Host layout / chrome ─────────────────────────────────────────
_coop_lay ()
{
	_W=$TUISH_COLUMNS; _H=$TUISH_LINES
	_top=3
	_bot=$(( _H - 1 ))
	_bh=$(( _bot - _top + 1 ))
	_half=$(( (_W - 3) / 2 ))
	_lc=2
	_rc=$(( _lc + _half + 1 ))
	# Region interiors (inside each box border), in absolute host cells.
	_li_r=$(( _top + 1 )); _li_c=$(( _lc + 1 )); _li_w=$(( _half - 2 )); _li_h=$(( _bh - 2 ))
	_ri_r=$(( _top + 1 )); _ri_c=$(( _rc + 1 )); _ri_w=$(( _half - 2 )); _ri_h=$(( _bh - 2 ))
}

_coop_frame ()
{
	tuish_begin
	tuish_draw_fill 1 1 "$_W" "$_H" bg=$C_BG
	tuish_text 1 2 "cooperative — one loop, two live apps" fg=$C_ACCENT bg=$C_BG
	local _hint='mouse: focus a box · type: editor · Ctrl+W: quit'
	tuish_str_width _hint; local _hw=$TUISH_SWIDTH
	tuish_text 1 $(( _W - _hw )) "$_hint" fg=$C_DIM bg=$C_BG
	tuish_draw_box "$_top" "$_lc" "$_half" "$_bh" fg=$C_BORDER bg=$C_BG style=rounded
	tuish_text "$_top" $(( _lc + 2 )) " clock " fg=$C_ACCENT2 bg=$C_BG
	tuish_draw_box "$_top" "$_rc" "$_half" "$_bh" fg=$C_ACCENT bg=$C_BG style=rounded
	tuish_text "$_top" $(( _rc + 2 )) " editor " fg=$C_ACCENT bg=$C_BG
	tuish_end
}

# Is host-absolute (x,y) inside the interior rectangle r,c,w,h?
_coop_in ()   # $1=x $2=y $3=r $4=c $5=w $6=h  -> return 0 if inside
{
	test "$1" -ge "$4" && test "$1" -lt $(( $4 + $5 )) \
		&& test "$2" -ge "$3" && test "$2" -lt $(( $3 + $6 ))
}

# Re-seat a child's region to r,c,w,h (host-absolute) after a resize, so it relayouts
# into the moved rectangle instead of stale geometry. Mirrors tuish_ctx_create_region's
# field seeding; the host is fullscreen (identity), so interior cells are absolute.
_coop_reseat ()   # $1=ctx $2=r $3=c $4=w $5=h
{
	local _host=$_tuish_ctx_active
	tuish_ctx_activate "$1"
	TUISH_VIEW_TOP=$2; TUISH_VIEW_LEFT=$(( $3 - 1 ))
	TUISH_VIEW_ROWS=$5; TUISH_VIEW_COLS=$4
	_tuish_rgn_top=$2; _tuish_rgn_left=$(( $3 - 1 ))
	_tuish_rgn_rows=$5; _tuish_rgn_cols=$4
	_tuish_base_lrmin=1; _tuish_base_lrmax=$5
	_tuish_base_lcmin=1; _tuish_base_lcmax=$4
	_tuish_tx_reset
	tuish_ctx_activate "$_host"
}

# ─── The cooperative router ───────────────────────────────────────
# The host's event handler. The host loop has already decoded the event in the host
# context (host-absolute coords); we route it to the right child and drive that child
# with the same raw descriptor via tuish_ctx_dispatch (which re-resolves it in the
# child's region-local frame). Nothing here runs a nested loop.
_coop_on_event ()
{
	case "$TUISH_EVENT_KIND" in
		mouse)
			if _coop_in "$TUISH_MOUSE_X" "$TUISH_MOUSE_Y" "$_li_r" "$_li_c" "$_li_w" "$_li_h"
			then tuish_ctx_dispatch "$_clk_ctx"
			elif _coop_in "$TUISH_MOUSE_X" "$TUISH_MOUSE_Y" "$_ri_r" "$_ri_c" "$_ri_w" "$_ri_h"
			then tuish_ctx_dispatch "$_ed_ctx"
			fi
			;;
		key)
			case "$TUISH_EVENT" in
				ctrl-w) tuish_quit_clear;;
				*)      tuish_ctx_dispatch "$_ed_ctx";;   # keyboard → the editor
			esac
			;;
		idle)
			tuish_ctx_dispatch "$_clk_ctx"               # tick BOTH children
			tuish_ctx_dispatch "$_ed_ctx"
			;;
		signal)
			_coop_lay
			_coop_reseat "$_clk_ctx" "$_li_r" "$_li_c" "$_li_w" "$_li_h"
			_coop_reseat "$_ed_ctx"  "$_ri_r" "$_ri_c" "$_ri_w" "$_ri_h"
			_coop_frame
			tuish_ctx_dispatch "$_clk_ctx"
			tuish_ctx_dispatch "$_ed_ctx"
			;;
	esac
}

# ─── Host entry ───────────────────────────────────────────────────
_coop_main ()
{
	tuish_init
	tuish_mouse_on
	tuish_viewport fullscreen
	_coop_lay
	_coop_frame

	# Mount both children: each runs its non-blocking setup in a region of ours and
	# paints itself; we keep the loop. tuish_ctx_mount returns the child id in TUISH_CTX.
	tuish_ctx_mount "$_li_r" "$_li_c" "$_li_w" "$_li_h" _clk_setup
	_clk_ctx=$TUISH_CTX
	tuish_ctx_mount "$_ri_r" "$_ri_c" "$_ri_w" "$_ri_h" _ed_setup
	_ed_ctx=$TUISH_CTX

	# Drive everything from one loop through the router (registered by name in the
	# host's own context, so the children's handlers are untouched). The router fully
	# owns routing, so the host needs no bindings of its own.
	tuish_on_event _coop_on_event

	tuish_run || :

	tuish_ctx_unmount "$_ed_ctx"    # the editor's own fini hook restores the cursor
	tuish_ctx_unmount "$_clk_ctx"
	tuish_fini
}

if test "${_coop_standalone:-0}" -eq 1
then
	_coop_main
fi
