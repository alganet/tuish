#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/host.sh - Hosting several live children in one event loop.
# Source after tui.sh and event.sh (and keybind.sh, if the host binds keys).
#
# tui.sh gives you the primitives: mount a child in a region, move it, clip it, drive it,
# tick it. This module is what you end up writing ON TOP of them the second time — a table
# of children, and the handful of rules that make them behave. It exists because two hosts
# wrote it independently (the website and examples/cooperative.sh) and only one of them got
# it right.
#
#   tuish_host_pane R C W H         the window children are seen through (optional)
#   tuish_host_begin                start (re)declaring the child list
#   tuish_host_slot ID FN [ARG] R C W H [modal]
#   tuish_host_commit               reconcile: mount / reseat / unmount, adopt the tick
#
#   tuish_host_paint                render live children into the host's OPEN frame
#   tuish_host_route                the standard router; returns 1 if nothing took it
#   tuish_host_focus [ID]           get / set the child holding the keyboard
#   tuish_host_at X Y               which child is under (x,y)? -> TUISH_HOST_HIT
#   tuish_host_owns_row ROW         does a live child own that screen row?
#   tuish_host_ctx ID               that child's context id -> TUISH_HOST_CTX
#
# The host still owns LAYOUT: it says where each child goes, every time. This module never
# learns what a "scroll offset" or a "line of text" is — you hand it rectangles.

# ─── State ───────────────────────────────────────────────────────
# One table, eval-indexed (the idiom the rest of the toolkit uses). A slot is:
#   id    caller's stable key. NOT the rectangle — see tuish_host_slot.
#   fn    setup function, arg  its argument (or '')
#   r c w h   where it goes, in the host's logical coords. May be OUTSIDE the pane.
#   modal 1 if it owns its region outright (see tuish_host_route)
#   ctx   its context, once mounted ('' = not mounted)
_th_n=0                 # live slots
_th_focus=''            # id of the child holding the keyboard ('' = the host)
_th_pane=''             # "R C W H", or '' for no pane
_th_interval=''         # the host's own tick, to restore when the last child goes

_th_decl_n=0            # slots declared since tuish_host_begin

TUISH_HOST_HIT=''       # out: tuish_host_at
TUISH_HOST_CTX=''       # out: tuish_host_ctx
TUISH_HOST_DROVE=''     # out: the id tuish_host_route handed the event to
TUISH_HOST_QUIT=''      # out: the id of a child that ended ITSELF

# ─── The pane ────────────────────────────────────────────────────
# The window children are seen through. Children may be seated partly (or wholly) outside
# it — that is a child scrolled under an edge, and it is CLIPPED, not resized. Without a
# pane, children are simply not clipped.
tuish_host_pane ()   # $1=R $2=C $3=W $4=H
{
	_th_pane="$1 $2 $3 $4"
	tuish_ctx_clip "$1" "$2" "$3" "$4"
	return 0
}

# ─── Declaring children ──────────────────────────────────────────
# Declarative, and meant to be re-run whenever the layout changes:
#
#   tuish_host_begin
#   tuish_host_slot clock _clk_setup '' 4 2 30 10
#   tuish_host_slot edit  _ed_setup  '' 4 34 30 10
#   tuish_host_commit
#
# ID is yours and must be STABLE — it is the identity tuish_host_commit reconciles on. It
# is deliberately not the rectangle: a scrolling host re-declares every child at a new row
# on every wheel tick, and if the row were part of the identity, every child would be torn
# down and remounted (and repainted) sixty times a second.
tuish_host_begin () { _th_decl_n=0; return 0; }

tuish_host_slot ()   # $1=ID $2=FN $3=ARG $4=R $5=C $6=W $7=H [$8=modal]
{
	_th_decl_n=$(( _th_decl_n + 1 ))
	eval "_th_d_id_$_th_decl_n=\$1  _th_d_fn_$_th_decl_n=\$2  _th_d_arg_$_th_decl_n=\$3
	      _th_d_r_$_th_decl_n=\$4   _th_d_c_$_th_decl_n=\$5
	      _th_d_w_$_th_decl_n=\$6   _th_d_h_$_th_decl_n=\$7
	      _th_d_modal_$_th_decl_n=\${8:-}"
	return 0
}

# Reconcile the declared list against the live one.
#
#   same id, still visible  -> KEEP the context, just reseat it
#   new id, visible         -> mount it (clipped from its first paint)
#   gone, or wholly off-pane-> unmount it
#
# Keeping the context is the whole point. A host rebuilds its child list for all sorts of
# reasons that have nothing to do with most of the children — the website rebuilds the
# entire page to toggle ONE code block — and remounting them all would repaint them all,
# one write each, before the real repaint even started. That is a visible flash.
tuish_host_commit ()
{
	local _i=1 _j _id _fn _arg _r _c _w _h _modal _ctx _keep
	local _old_n=$_th_n

	# Snapshot the live table; we rebuild over it.
	_j=1
	while test $_j -le $_old_n
	do
		eval "_th_o_id_$_j=\$_th_id_$_j _th_o_ctx_$_j=\$_th_ctx_$_j"
		_j=$(( _j + 1 ))
	done

	_th_n=0
	while test $_i -le $_th_decl_n
	do
		eval "_id=\$_th_d_id_$_i    _fn=\$_th_d_fn_$_i _arg=\$_th_d_arg_$_i
		      _r=\$_th_d_r_$_i      _c=\$_th_d_c_$_i
		      _w=\$_th_d_w_$_i      _h=\$_th_d_h_$_i
		      _modal=\$_th_d_modal_$_i"

		# Claim the context this id had, if any.
		_ctx=''
		_j=1
		while test $_j -le $_old_n
		do
			eval "_keep=\$_th_o_id_$_j"
			if test "$_keep" = "$_id"
			then eval "_ctx=\$_th_o_ctx_$_j _th_o_ctx_$_j=''"; break; fi
			_j=$(( _j + 1 ))
		done

		_th_n=$(( _th_n + 1 ))
		eval "_th_id_$_th_n=\$_id       _th_fn_$_th_n=\$_fn   _th_arg_$_th_n=\$_arg
		      _th_r_$_th_n=\$_r         _th_c_$_th_n=\$_c
		      _th_w_$_th_n=\$_w         _th_h_$_th_n=\$_h
		      _th_modal_$_th_n=\$_modal _th_ctx_$_th_n=\$_ctx"

		if _th_offpane "$_r" "$_c" "$_w" "$_h"
		then
			# Entirely out of sight: drop it. Pure resource management — it comes back
			# when it scrolls into view.
			test -n "$_ctx" && _th_unmount $_th_n
		elif test -z "$_ctx"
		then
			if test -n "$_arg"
			then tuish_ctx_mount "$_r" "$_c" "$_w" "$_h" "$_fn" "$_arg"
			else tuish_ctx_mount "$_r" "$_c" "$_w" "$_h" "$_fn"
			fi
			eval "_th_ctx_$_th_n=\$TUISH_CTX"
		else
			tuish_ctx_reseat "$_ctx" "$_r" "$_c" "$_w" "$_h"
		fi
		_i=$(( _i + 1 ))
	done

	# Whatever nothing claimed is gone from the host: unmount it.
	_j=1
	while test $_j -le $_old_n
	do
		eval "_ctx=\$_th_o_ctx_$_j _id=\$_th_o_id_$_j"
		if test -n "$_ctx"
		then
			tuish_ctx_unmount "$_ctx"
			test "$_th_focus" = "$_id" && _th_focus=''
		fi
		_j=$(( _j + 1 ))
	done

	_th_adopt_interval
	return 0
}

# Wholly outside the pane? (No pane = never.)
_th_offpane ()   # $1=R $2=C $3=W $4=H
{
	test -n "$_th_pane" || return 1
	local _q="$_th_pane" _pr _pc _pw _ph
	_pr="${_q%% *}"; _q="${_q#* }"
	_pc="${_q%% *}"; _q="${_q#* }"
	_pw="${_q%% *}"; _ph="${_q##* }"
	test $(( $1 + $4 - 1 )) -lt "$_pr" && return 0
	test "$1" -gt $(( _pr + _ph - 1 ))  && return 0
	test $(( $2 + $3 - 1 )) -lt "$_pc" && return 0
	test "$2" -gt $(( _pc + _pw - 1 ))  && return 0
	return 1
}

_th_unmount ()   # $1 = slot index
{
	local _c _id
	eval "_c=\$_th_ctx_$1 _id=\$_th_id_$1"
	test -n "$_c" || return 0
	tuish_ctx_unmount "$_c"
	eval "_th_ctx_$1=''"
	test "$_th_focus" = "$_id" && _th_focus=''
	return 0
}

# Poll at the FASTEST live child's rate, so a 50Hz game is not throttled by a 1Hz clock
# beside it; tuish_ctx_tick then divides that back down per child, so the clock is not sped
# up either. With no children left, go back to the host's own tick.
_th_adopt_interval ()
{
	local _i=1 _c _ids=''
	while test $_i -le $_th_n
	do
		eval "_c=\$_th_ctx_$_i"
		test -n "$_c" && _ids="$_ids $_c"
		_i=$(( _i + 1 ))
	done
	test -n "$_th_interval" || _th_interval=$_tuish_interval_s
	tuish_idle_interval "$_th_interval"
	test -n "$_ids" && tuish_ctx_sync_interval $_ids
	return 0
}

# ─── Lookups ─────────────────────────────────────────────────────
tuish_host_ctx ()   # $1 = id -> TUISH_HOST_CTX ('' = not mounted / unknown)
{
	local _i=1 _id
	TUISH_HOST_CTX=''
	while test $_i -le $_th_n
	do
		eval "_id=\$_th_id_$_i"
		if test "$_id" = "$1"
		then eval "TUISH_HOST_CTX=\$_th_ctx_$_i"; return 0; fi
		_i=$(( _i + 1 ))
	done
	return 0
}

# Which child is under host-absolute (x,y)? -> TUISH_HOST_HIT
#
# CLIP-AWARE: the part of a child that has scrolled out of the pane is not clickable, even
# though its rectangle nominally still covers those rows. You cannot click what you cannot
# see, and a host that gets this wrong routes clicks to a widget hidden behind its own
# chrome.
tuish_host_at ()   # $1=x $2=y
{
	local _i=1 _c _r _cc _w _h _t _b _l _rr
	TUISH_HOST_HIT=''
	while test $_i -le $_th_n
	do
		eval "_c=\$_th_ctx_$_i _r=\$_th_r_$_i _cc=\$_th_c_$_i _w=\$_th_w_$_i _h=\$_th_h_$_i"
		if test -n "$_c"
		then
			_t=$_r; _b=$(( _r + _h - 1 )); _l=$_cc; _rr=$(( _cc + _w - 1 ))
			_th_clamp_to_pane
			if test "$1" -ge "$_l" && test "$1" -le "$_rr" \
			   && test "$2" -ge "$_t" && test "$2" -le "$_b"
			then eval "TUISH_HOST_HIT=\$_th_id_$_i"; return 0; fi
		fi
		_i=$(( _i + 1 ))
	done
	return 0
}

# Clamp _t/_b/_l/_rr to the pane (no pane: leave them).
_th_clamp_to_pane ()
{
	test -n "$_th_pane" || return 0
	local _q="$_th_pane" _pr _pc _pw _ph
	_pr="${_q%% *}"; _q="${_q#* }"
	_pc="${_q%% *}"; _q="${_q#* }"
	_pw="${_q%% *}"; _ph="${_q##* }"
	test "$_t" -lt "$_pr" && _t=$_pr
	test "$_b" -gt $(( _pr + _ph - 1 )) && _b=$(( _pr + _ph - 1 ))
	test "$_l" -lt "$_pc" && _l=$_pc
	test "$_rr" -gt $(( _pc + _pw - 1 )) && _rr=$(( _pc + _pw - 1 ))
	return 0
}

# Does a live child own screen row $1? A host that draws its own content AROUND its
# children asks this before it paints a row — those rows belong to the child, and filling
# them would wipe a running app on every repaint.
tuish_host_owns_row ()   # $1 = absolute screen row
{
	local _i=1 _c _r _cc _w _h _t _b _l _rr
	while test $_i -le $_th_n
	do
		eval "_c=\$_th_ctx_$_i _r=\$_th_r_$_i _cc=\$_th_c_$_i _w=\$_th_w_$_i _h=\$_th_h_$_i"
		if test -n "$_c"
		then
			_t=$_r; _b=$(( _r + _h - 1 )); _l=$_cc; _rr=$(( _cc + _w - 1 ))
			_th_clamp_to_pane
			test "$1" -ge "$_t" && test "$1" -le "$_b" && return 0
		fi
		_i=$(( _i + 1 ))
	done
	return 1
}

# ─── Focus ───────────────────────────────────────────────────────
# Which child has the keyboard. '' is the host itself.
tuish_host_focus ()   # [$1 = id]
{
	if test $# -ge 1
	then _th_focus="$1"
	else printf '%s' "$_th_focus"
	fi
	return 0
}

# ─── Painting ────────────────────────────────────────────────────
# Render every live child. Call this INSIDE your own tuish_begin/tuish_end and AFTER your
# chrome — tuish_ctx_render splices into the open frame, so the whole repaint (background,
# chrome, and every child) goes out as ONE write. Paint the children first and your
# background fill lands on top of them; paint them in a frame of their own and the terminal
# draws each one separately, and you see the chrome move a frame before the children do.
#
# The FOCUSED child is painted LAST, and that is about the caret. A child that wants one
# shows it where it wants it (editor.sh does, via tuish_cursor) — but the next child to
# paint drags the terminal's cursor off to wherever ITS last cell was, leaving a caret
# blinking in the middle of somebody else's box. Painting the focused child last means the
# caret ends the frame where the thing you are typing into put it.
#
# The caret is hidden first, because a host without a focused child should not have one at
# all: a document does not blink at you.
tuish_host_paint ()
{
	local _i=1 _c _id _fc=''
	tuish_hide_cursor
	while test $_i -le $_th_n
	do
		eval "_c=\$_th_ctx_$_i _id=\$_th_id_$_i"
		if test -n "$_c"
		then
			if test "$_id" = "$_th_focus"
			then _fc=$_c
			else tuish_ctx_render "$_c"
			fi
		fi
		_i=$(( _i + 1 ))
	done
	test -n "$_fc" && tuish_ctx_render "$_fc"
	return 0
}

# Repaint ONLY the focused child. For the cheap partial repaints a host does that do not
# touch the children at all — a hover highlight in a sidebar, say. The framework hides the
# caret before every deferred render, so a frame that repaints nothing containing a caret
# would blink it out from under someone who is typing. This puts it back, for the price of
# one small widget.
tuish_host_paint_focus ()
{
	test -n "$_th_focus" || return 0
	tuish_host_ctx "$_th_focus"
	test -n "$TUISH_HOST_CTX" && tuish_ctx_render "$TUISH_HOST_CTX"
	return 0
}

# ─── Routing ─────────────────────────────────────────────────────
# The standard policy. Returns 0 if a child took the event, 1 if it is the host's.
#
#   mouse   the child under the pointer; a click also FOCUSES it. If the child does not
#           act on the event, it CHAINS back to the host (see below).
#   key     the focused child.
#   paste   the focused child.
#   idle    every live child, each at ITS OWN rate (tuish_ctx_tick, not dispatch).
#   signal  nothing — a resize means your layout changed, so YOU re-declare the children
#           (tuish_host_begin/slot/commit) and repaint. This module cannot guess the new
#           rectangles.
#
# SCROLL CHAINING. An event offered to a child that does nothing with it comes back. Route
# it purely by position and the wheel over a widget that scrolls nothing kills the host's
# scrolling entirely — and it can never recover, because nothing then moves the widget out
# from under the pointer. TUISH_CTX_HANDLED (tui.sh) and tuish_pass (event.sh) are what
# make "the child declined it" a thing a host can see.
#
# A MODAL child is the exception: it owns its region, there is nothing behind it to scroll,
# and it consumes what it is given.
#
# QUITTING. A child ends by ITS OWN means and we detect it (TUISH_CTX_QUIT) rather than
# intercepting its quit key — a host cannot know which key an app exits on, and the
# terminal or browser may reserve it anyway. The id lands in TUISH_HOST_QUIT; what a child
# quitting MEANS is the host's business, so route does not unmount it for you.
tuish_host_route ()
{
	local _c _id _modal _i=1
	TUISH_HOST_DROVE=''
	TUISH_HOST_QUIT=''

	case "$TUISH_EVENT_KIND" in
		mouse)
			test "$_th_n" -gt 0 || return 1
			tuish_host_at "$TUISH_MOUSE_X" "$TUISH_MOUSE_Y"
			test -n "$TUISH_HOST_HIT" || return 1
			_id=$TUISH_HOST_HIT
			tuish_host_ctx "$_id"; _c=$TUISH_HOST_CTX
			test -n "$_c" || return 1
			_th_modal_of "$_id"; _modal=$_th_modal_out

			case "$TUISH_EVENT" in
				*clik) _th_focus="$_id";;
			esac
			tuish_ctx_dispatch "$_c"
			TUISH_HOST_DROVE=$_id
			test "$TUISH_CTX_QUIT" = 1 && TUISH_HOST_QUIT=$_id
			test "$_modal" = 'modal' && return 0
			test "$TUISH_CTX_HANDLED" -eq 1 && return 0
			return 1                       # declined: it chains back to the host
			;;
		key|paste)
			test -n "$_th_focus" || return 1
			tuish_host_ctx "$_th_focus"; _c=$TUISH_HOST_CTX
			test -n "$_c" || return 1
			tuish_ctx_dispatch "$_c"
			TUISH_HOST_DROVE=$_th_focus
			test "$TUISH_CTX_QUIT" = 1 && TUISH_HOST_QUIT=$_th_focus
			_th_modal_of "$_th_focus"
			test "$_th_modal_out" = 'modal' && return 0
			test "$TUISH_CTX_HANDLED" -eq 1 && return 0
			return 1
			;;
		idle)
			test "$_th_n" -gt 0 || return 1
			while test $_i -le $_th_n
			do
				eval "_c=\$_th_ctx_$_i"
				if test -n "$_c"
				then
					tuish_ctx_tick "$_c"
					test "$TUISH_CTX_QUIT" = 1 && eval "TUISH_HOST_QUIT=\$_th_id_$_i"
				fi
				_i=$(( _i + 1 ))
			done
			return 1                       # an idle tick is everybody's
			;;
	esac
	return 1
}

_th_modal_out=''
_th_modal_of ()   # $1 = id
{
	local _i=1 _id
	_th_modal_out=''
	while test $_i -le $_th_n
	do
		eval "_id=\$_th_id_$_i"
		if test "$_id" = "$1"
		then eval "_th_modal_out=\$_th_modal_$_i"; return 0; fi
		_i=$(( _i + 1 ))
	done
	return 0
}

# Unmount a child by id (the host's answer to TUISH_HOST_QUIT, usually).
tuish_host_drop ()   # $1 = id
{
	local _i=1 _id
	while test $_i -le $_th_n
	do
		eval "_id=\$_th_id_$_i"
		if test "$_id" = "$1"
		then _th_unmount $_i; _th_adopt_interval; return 0; fi
		_i=$(( _i + 1 ))
	done
	return 0
}

# Unmount everything (host teardown).
tuish_host_clear ()
{
	local _i=1
	while test $_i -le $_th_n
	do _th_unmount $_i; _i=$(( _i + 1 )); done
	_th_n=0
	_th_focus=''
	test -n "$_th_interval" && tuish_idle_interval "$_th_interval"
	return 0
}
