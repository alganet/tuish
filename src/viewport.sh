# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/viewport.sh - Viewport modes (fullscreen, fixed, grow)
# Optional module. Source after tui.sh and term.sh.
#
# Provides:
#   tuish_viewport MODE [MAX] - set viewport mode
#   tuish_grow                - emit line in grow mode
#
# Overrides:
#   _tuish_viewport_on_resize - resize handler (event.sh stub)
#   _tuish_on_fini            - viewport teardown (tui.sh stub)
#
# Variables (set by tuish_viewport, updated on resize):
#   TUISH_VIEW_MODE  - current mode: "fullscreen", "fixed", "grow", or ""
#   TUISH_VIEW_ROWS  - usable content rows in viewport
#   TUISH_VIEW_COLS  - usable content columns (= TUISH_COLUMNS)
#   TUISH_VIEW_TOP   - absolute terminal row where viewport starts (1-based)

# ─── Viewport state ───────────────────────────────────────────────
# _tuish_view_mode is initialized in tui.sh (viewport defaults).

_tuish_view_max=15
_tuish_view_origin=0
_tuish_view_anchor=0
_tuish_view_saved_origin=0
_tuish_view_saved_anchor=0
_tuish_view_altscreen=0
_tuish_view_phys=0
_tuish_view_grow_phase=0
_tuish_view_grow_count=0
_tuish_resize_cursor_row=0

# ─── Reserve space ───────────────────────────────────────────────

_tuish_viewport_reserve_space ()
{
	local _rows=${1:-$TUISH_VIEW_ROWS}
	local _needed=$((_tuish_view_origin + _rows - 1))
	if test $_needed -gt $TUISH_LINES
	then
		# Scroll by emitting _rows-1 newlines (reach bottom, then push)
		local _push=$((_rows - 1))
		local _i=0
		while test $_i -lt $_push
		do
			_tuish_write '\n'
			_i=$((_i + 1))
		done
		# Pin viewport to the bottom of the screen
		_tuish_view_origin=$((TUISH_LINES - _rows + 1))
		test $_tuish_view_origin -lt 1 && _tuish_view_origin=1
		TUISH_VIEW_TOP=$_tuish_view_origin
	fi
}

# Push content up so the invocation line (one row above the
# anchor) lands at terminal row 1, then pin origin to row 2.
_tuish_viewport_shrink_push ()
{
	# Compute auto-scroll from the queried post-resize cursor row.
	# Fall back to estimation when the DSR query returned no info.
	local _scroll=0
	local _post_row=$_tuish_resize_cursor_row
	test $_post_row -ge $_tuish_cursor_abs_row && _post_row=$TUISH_LINES
	test $_tuish_cursor_abs_row -gt $_post_row && \
		_scroll=$((_tuish_cursor_abs_row - _post_row))
	local _invoc=$((_tuish_view_anchor - 1 - _scroll))
	if test $_invoc -gt 1
	then
		tuish_move $TUISH_LINES 1
		local _i=0
		while test $_i -lt $((_invoc - 1))
		do
			_tuish_write '\n'
			_i=$((_i + 1))
		done
	fi
	if test $_invoc -le 0
	then
		# Invocation line was pushed into scrollback by terminal
		# auto-scroll — unrecoverable.  Use the full screen.
		_tuish_view_origin=1
	else
		_tuish_view_origin=2
		test $_tuish_view_origin -gt $TUISH_LINES && _tuish_view_origin=1
	fi
	_tuish_view_anchor=$_tuish_view_origin
}

# ─── Resize handler (overrides event.sh stub) ────────────────────

_tuish_viewport_on_resize ()
{
	_tuish_clipped=0
	local _old_cols=${_tuish_precols:-$TUISH_COLUMNS}
	local _old_lines=$TUISH_LINES
	local _old_phys=$_tuish_view_phys
	_tuish_precols=''

	# DSR query for actual cursor row after terminal auto-scroll
	# (emulators vary in scroll behaviour on resize).
	_tuish_resize_cursor_row=$_tuish_cursor_abs_row
	if type _tuish_get_byte >/dev/null 2>&1
	then
		_tuish_write '\033[6n'
		local _qst=0 _qrow=''
		while _tuish_get_byte -t1
		do
			case $_qst in
				0)
					_tuish_ord "$_tuish_byte"
					test $_tuish_code -eq 27 && _qst=1
					;;
				1)
					case "$_tuish_byte" in
						'[') _qst=2 ;;
						*) _qst=0 ;;
					esac
					;;
				2)
					case "$_tuish_byte" in
						[0-9]) _qrow="${_qrow}${_tuish_byte}" ;;
						';') _qst=3 ;;
						*) _qst=0; _qrow='' ;;
					esac
					;;
				3)
					case "$_tuish_byte" in
						[0-9]) ;;
						R)
							test -n "$_qrow" && \
								_tuish_resize_cursor_row=$_qrow
							break
							;;
						*) _qst=0; _qrow='' ;;
					esac
					;;
			esac
		done
	fi

	# Reset scroll region (some terminals clip it on resize).
	tuish_reset_scroll

	tuish_update_size
	TUISH_VIEW_COLS=$TUISH_COLUMNS

	# On shrink: push content so invocation line reaches row 1.
	# On grow: keep anchor, expand VIEW_ROWS.
	local _shrunk=0
	test $TUISH_LINES -lt $_old_lines && _shrunk=1

	case "$_tuish_view_mode" in
		fullscreen)
			TUISH_VIEW_ROWS=$TUISH_LINES
			_tuish_view_phys=$TUISH_LINES
			;;
		fixed)
			if test $_shrunk -eq 1
			then
				_tuish_viewport_shrink_push
			fi

			# Logical VIEW_ROWS stays at max; physical rows clip to screen
			TUISH_VIEW_ROWS=$_tuish_view_max
			local _avail=$((TUISH_LINES - _tuish_view_origin + 1))
			test $_avail -lt 1 && _avail=1
			local _phys=$_tuish_view_max
			test $_phys -gt $_avail && _phys=$_avail
			test $_phys -lt 1 && _phys=1
			_tuish_view_phys=$_phys

			TUISH_VIEW_TOP=$_tuish_view_origin
			local _bot=$((_tuish_view_origin + _phys - 1))

			# Clear stale lines below/around viewport.
			local _cf _ct
			if test $_shrunk -eq 1
			then
				_cf=$((_bot + 1))
				_ct=$TUISH_LINES
			elif test "$_old_cols" -ne "$TUISH_COLUMNS"
			then
				_cf=$_tuish_view_origin
				_ct=$TUISH_LINES
			else
				_cf=$((_bot + 1))
				_ct=$((_tuish_view_origin + _old_phys + 2))
				test $_ct -lt $((_cf + 3)) && _ct=$((_cf + 3))
			fi
			while test $_cf -le $_ct && test $_cf -le $TUISH_LINES
			do
				tuish_move $_cf 1
				tuish_clear_line
				_cf=$((_cf + 1))
			done
			tuish_scroll_region $_tuish_view_origin $_bot
			;;
		grow)
			if test $_tuish_view_grow_phase -eq 1
			then
				local _old_gphys=$_tuish_view_phys

				if test $_shrunk -eq 1
				then
					_tuish_viewport_shrink_push
				fi

				# Clip to available space
				local _avail=$((TUISH_LINES - _tuish_view_origin))
				test $_avail -gt $_tuish_view_grow_count && _avail=$_tuish_view_grow_count
				test $_avail -lt 1 && _avail=1
				local _bot=$((_tuish_view_origin + _avail))
				test $_bot -gt $TUISH_LINES && _bot=$TUISH_LINES

				TUISH_VIEW_TOP=$((_tuish_view_origin + 1))
				TUISH_VIEW_ROWS=$((_bot - _tuish_view_origin))
				_tuish_view_phys=$TUISH_VIEW_ROWS

				# Clear stale lines below/around viewport
				local _cf _ct
				if test $_shrunk -eq 1
				then
					_cf=$((_bot + 1))
					_ct=$TUISH_LINES
				elif test "$_old_cols" -ne "$TUISH_COLUMNS"
				then
					_cf=$((_tuish_view_origin + 1))
					_ct=$TUISH_LINES
				else
					_cf=$((_bot + 1))
					_ct=$((_tuish_view_origin + _old_gphys + 2))
					test $_ct -lt $((_cf + 3)) && _ct=$((_cf + 3))
				fi
				while test $_cf -le $_ct && test $_cf -le $TUISH_LINES
				do
					tuish_move $_cf 1
					tuish_clear_line
					_cf=$((_cf + 1))
				done
				tuish_scroll_region $((_tuish_view_origin + 1)) $_bot
			fi
			;;
	esac
}

# ─── Viewport modes ──────────────────────────────────────────────

tuish_viewport ()
{
	local _new_mode="$1"
	local _new_max="${2:-$_tuish_view_max}"

	# Structural sequences must reach the terminal immediately;
	# bypass event-loop buffering.
	_tuish_clipped=0
	local _vp_was_buffering=$_tuish_buffering
	test $_tuish_buffering -eq 1 && tuish_flush
	_tuish_buffering=0

	# Tear down previous mode
	case "$_tuish_view_mode" in
		fullscreen)
			tuish_altscreen_off
			_tuish_view_altscreen=0
			# ?1049h/l corrupt DECSC state; re-save at init position
			tuish_move $TUISH_INIT_ROW 1
			tuish_save_cursor
			;;
		fixed|grow)
			tuish_reset_scroll
			# Clear viewport and save origin for fullscreen return.
			if test "$_new_mode" = 'fullscreen'
			then
				_tuish_view_saved_origin=$_tuish_view_origin
				_tuish_view_saved_anchor=$_tuish_view_anchor
				local _vc=0 _vn=$_tuish_view_phys
				test "$_tuish_view_mode" = 'grow' && _vn=$((_tuish_view_grow_count + 1))
				while test $_vc -lt $_vn
				do
					tuish_move $((_tuish_view_origin + _vc)) 1
					tuish_clear_line
					_vc=$((_vc + 1))
				done
			fi
			;;
	esac

	_tuish_view_mode="$_new_mode"
	_tuish_view_max=$_new_max
	TUISH_VIEW_MODE="$_new_mode"

	# Set up new mode
	case "$_new_mode" in
		fullscreen)
			tuish_altscreen_on
			_tuish_view_altscreen=1
			tuish_clear_screen
			TUISH_VIEW_TOP=1
			TUISH_VIEW_ROWS=$TUISH_LINES
			_tuish_view_phys=$TUISH_LINES
			TUISH_VIEW_COLS=$TUISH_COLUMNS
			;;
		fixed)
			if test $_tuish_view_saved_origin -gt 0
			then
				# Returning from fullscreen: reuse saved origin
				_tuish_view_origin=$_tuish_view_saved_origin
				_tuish_view_anchor=$_tuish_view_saved_anchor
				_tuish_view_saved_origin=0
				_tuish_view_saved_anchor=0
			else
				_tuish_view_origin=$TUISH_INIT_ROW
			fi
			TUISH_VIEW_TOP=$_tuish_view_origin
			TUISH_VIEW_ROWS=$_tuish_view_max
			TUISH_VIEW_COLS=$TUISH_COLUMNS
			# Physical rows: clip to screen, preserve invocation line
			local _phys=$_tuish_view_max
			local _max_phys=$((TUISH_LINES - 1))
			test $_max_phys -lt 1 && _max_phys=1
			test $_phys -gt $_max_phys && _phys=$_max_phys
			if test $_tuish_view_origin -eq $TUISH_INIT_ROW
			then
				_tuish_viewport_reserve_space $_phys
				# Set anchor after push (or no-push) has finalised origin
				_tuish_view_anchor=$_tuish_view_origin
			fi
			local _bot=$((_tuish_view_origin + _phys - 1))
			# Clamp to screen if terminal shrank while on alt screen
			test $_bot -gt $TUISH_LINES && _bot=$TUISH_LINES && _phys=$((_bot - _tuish_view_origin + 1))
			_tuish_view_phys=$_phys
			tuish_scroll_region $_tuish_view_origin $_bot
			# Clear the viewport area
			local _r=$_tuish_view_origin
			while test $_r -le $_bot
			do
				tuish_move $_r 1
				tuish_clear_line
				_r=$((_r + 1))
			done
			;;
		grow)
			if test $_tuish_view_saved_origin -gt 0
			then
				_tuish_view_origin=$_tuish_view_saved_origin
				_tuish_view_anchor=$_tuish_view_saved_anchor
				_tuish_view_saved_origin=0
				_tuish_view_saved_anchor=0
			else
				_tuish_view_origin=$TUISH_INIT_ROW
				_tuish_view_anchor=$TUISH_INIT_ROW
			fi
			_tuish_view_grow_phase=0
			_tuish_view_grow_count=0
			TUISH_VIEW_TOP=$_tuish_view_origin
			TUISH_VIEW_ROWS=0
			_tuish_view_phys=0
			TUISH_VIEW_COLS=$TUISH_COLUMNS
			;;
	esac

	_tuish_buffering=$_vp_was_buffering
}

tuish_grow ()
{
	# Phase 0: growing
	if test $_tuish_view_grow_phase -eq 0
	then
		if test $_tuish_view_grow_count -lt $_tuish_view_max &&
		   test $_tuish_view_grow_count -lt $TUISH_LINES
		then
			tuish_newline
			_tuish_view_grow_count=$((_tuish_view_grow_count + 1))
			TUISH_VIEW_ROWS=$_tuish_view_grow_count
			return
		fi

		# Transition to scrolling
		_tuish_view_grow_phase=1
		local _bot=$((TUISH_INIT_ROW + _tuish_view_grow_count))
		_tuish_view_origin=$TUISH_INIT_ROW
		if test $_bot -gt $TUISH_LINES
		then
			_bot=$TUISH_LINES
			_tuish_view_origin=$((_bot - _tuish_view_grow_count))
			test $_tuish_view_origin -lt 1 && _tuish_view_origin=1
		fi
		_tuish_view_anchor=$_tuish_view_origin
		TUISH_VIEW_TOP=$((_tuish_view_origin + 1))
		TUISH_VIEW_ROWS=$((_bot - _tuish_view_origin))
		tuish_scroll_region $((_tuish_view_origin + 1)) $_bot
		tuish_move $_bot 1
	fi

	# Phase 1: scrolling
	tuish_newline
}

# ─── Fini hook (overrides tui.sh stub) ───────────────────────────

_tuish_on_fini ()
{
	# Compute push gap so cursor lands after the last history line.
	if test "$_tuish_view_mode" = 'fullscreen'
	then
		# Was previously in fixed/grow with pushed origin
		if test $_tuish_view_saved_origin -gt 0 &&
		   test $_tuish_view_saved_origin -lt $TUISH_INIT_ROW
		then
			_tuish_fini_push_gap=$((TUISH_INIT_ROW - _tuish_view_saved_origin))
		fi
	elif test "$_tuish_view_mode" = 'fixed' || test "$_tuish_view_mode" = 'grow'
	then
		# Grow phase 0: recompute origin (scrolled past bottom)
		if test "$_tuish_view_mode" = 'grow' && test $_tuish_view_grow_phase -eq 0
		then
			local _bot=$((TUISH_INIT_ROW + _tuish_view_grow_count))
			if test $_bot -gt $TUISH_LINES
			then
				_tuish_view_origin=$(($TUISH_LINES - _tuish_view_grow_count))
				test $_tuish_view_origin -lt 1 && _tuish_view_origin=1
			fi
		fi
		if test $_tuish_view_origin -lt $TUISH_INIT_ROW
		then
			_tuish_fini_push_gap=$((TUISH_INIT_ROW - _tuish_view_origin))
		fi
	fi

	# Tear down active viewport mode
	if test "$_tuish_view_mode" = 'fullscreen'
	then
		tuish_clear_screen
		tuish_altscreen_off
		_tuish_view_altscreen=0
		# ?1049h/l corrupts DECSC state; re-save at init position
		tuish_move $TUISH_INIT_ROW 1
		tuish_save_cursor
		_tuish_view_mode=''
	fi
	if test "$_tuish_view_mode" = 'fixed' || test "$_tuish_view_mode" = 'grow'
	then
		tuish_reset_scroll
		case "$_tuish_quit_mode" in
			clear)
				local _vr=$_tuish_view_phys
				test "$_tuish_view_mode" = 'grow' && _vr=$((_tuish_view_grow_count + 1))
				if test $_vr -gt 0
				then
					local _r=0
					while test $_r -lt $_vr
					do
						tuish_move $((_tuish_view_origin + _r)) 1
						tuish_clear_line
						_r=$((_r + 1))
					done
				fi
				# Re-save cursor at viewport origin for correct DECRC
				tuish_move $_tuish_view_origin 1
				tuish_save_cursor
				_tuish_fini_push_gap=0
				;;
			main)
				if test "$_tuish_view_mode" = 'fixed'
				then
					TUISH_FINI_OFFSET=$_tuish_view_phys
				elif test $_tuish_view_grow_count -gt 0
				then
					TUISH_FINI_OFFSET=$((_tuish_view_grow_count + 1))
				fi
				;;
		esac
	fi
	_tuish_view_mode=''
}
