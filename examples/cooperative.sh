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
#   Input model — mouse routes by region (whichever box it is over); the keyboard goes
#   to the editor; idle ticks BOTH children, each at its own negotiated rate (the clock
#   asks for 1Hz, the editor keeps the default, and the host polls at the faster of the
#   two). Ctrl+W reaches the editor, which quits itself; the host sees TUISH_CTX_QUIT
#   and folds — it never has to know which key an embedded app uses to exit.
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
	# A clock displaying whole seconds needs a 1Hz tick, not the host's default ~4Hz —
	# so it ASKS for one. The host still polls at its own (faster) rate for the sake of
	# the editor; tuish_ctx_tick divides that down and only wakes us once a second. This
	# is the point of the negotiation: neither child imposes its clock on the other.
	tuish_idle_interval 1
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
			# All keys go to the editor — including its own quit (Ctrl+W). We do
			# NOT intercept the quit key here; instead we let the editor quit by its
			# own means and detect it (TUISH_CTX_QUIT), then fold the host. That is
			# the robust cooperative-quit model: the host never has to know which key
			# an embedded app uses to exit.
			tuish_ctx_dispatch "$_ed_ctx"                # keyboard → the editor
			test "$TUISH_CTX_QUIT" = 1 && tuish_quit_clear
			;;
		idle)
			# Tick BOTH children — each at ITS OWN rate. tuish_ctx_tick divides our
			# loop's tick down per child, so a child that asked for a slower clock is
			# not sped up by a host polling fast for a sibling (and vice versa: see
			# tuish_ctx_sync_interval in _coop_main).
			tuish_ctx_tick "$_clk_ctx"
			tuish_ctx_tick "$_ed_ctx"
			;;
		signal)
			_coop_lay
			tuish_ctx_reseat "$_clk_ctx" "$_li_r" "$_li_c" "$_li_w" "$_li_h"
			tuish_ctx_reseat "$_ed_ctx"  "$_ri_r" "$_ri_c" "$_ri_w" "$_ri_h"
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

	# Adopt the FASTEST tick the two children asked for, so neither is starved by our
	# loop; tuish_ctx_tick (in the idle branch) then divides it back down per child, so
	# neither is sped up either. Here: the editor keeps the default ~4Hz and the clock
	# asked for 1Hz, so we poll at 4Hz and wake the clock every 4th tick.
	tuish_ctx_sync_interval "$_clk_ctx" "$_ed_ctx"

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
