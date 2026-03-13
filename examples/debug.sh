#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# debug.sh - Event inspector using tui.sh
# Displays parsed events, raw codes, mouse positions, and terminal info.
# Ctrl+W to exit.

_dir="$(cd "$(dirname "$0")" && pwd)"
_tuish_src_dir="${_dir}/../src"
. "${_tuish_src_dir}/compat.sh"
. "${_tuish_src_dir}/ord.sh"
. "${_tuish_src_dir}/tui.sh"
. "${_tuish_src_dir}/term.sh"
. "${_tuish_src_dir}/event.sh"
. "${_tuish_src_dir}/hid.sh"
. "${_tuish_src_dir}/viewport.sh"
. "${_tuish_src_dir}/str.sh"
. "${_tuish_src_dir}/keybind.sh"

# ─── State ────────────────────────────────────────────────────────

_dbg_height="${TUISH_DEBUG_HEIGHT:-15}"
_dbg_count=0
_dbg_started=no

# ─── Display helpers ────────────────────────────────────────────────

_dbg_header ()
{
	tuish_sgr '7'
	tuish_print " tui.sh debug (quit: ctrl+w) | ${TUISH_COLUMNS}x${TUISH_LINES} | proto:${TUISH_PROTOCOL} | timing:${TUISH_TIMING} | row:${TUISH_INIT_ROW} "
	tuish_clear_to_eol
	tuish_sgr_reset
}

_dbg_format_event ()
{
	_dbg_count=$((_dbg_count + 1))
	local _num="$_dbg_count"
	local _pad='    '
	test $_num -ge 10 && _pad='   '
	test $_num -ge 100 && _pad='  '
	test $_num -ge 1000 && _pad=' '

	_dbg_left="${_pad}${_num}  ${TUISH_EVENT_KIND}:${TUISH_EVENT}"
	_dbg_right="[${TUISH_RAW}]"

	case "$TUISH_EVENT_KIND" in
		mouse)
			_dbg_right="x:${TUISH_MOUSE_X} y:${TUISH_MOUSE_ABS_Y}  [${TUISH_RAW}]"
			;;
		key)
			# Show display width for character events
			case "$TUISH_EVENT" in
				char\ *)
					local _ch="${TUISH_EVENT#char }"
					test "$_ch" = 'bslash' && _ch='\'
					tuish_str_width _ch
					_dbg_left="${_dbg_left} (w:${_tuish_swidth})"
					;;
			esac
			;;
	esac
}

_dbg_print_line ()
{
	_tuish_write '\r'
	tuish_print "$_dbg_left"
	# Right-align the raw codes
	local _llen=${#_dbg_left}
	local _rlen=${#_dbg_right}
	local _gap=$((TUISH_COLUMNS - _llen - _rlen - 1))
	if test $_gap -gt 0
	then
		_tuish_write "\033[${_gap}C"
	fi
	tuish_print "$_dbg_right"
	tuish_clear_to_eol
}

# ─── Actions ───────────────────────────────────────────────────────

_dbg_quit ()
{
	tuish_quit_main
}

_dbg_idle ()
{
	# Draw header on first idle (initial render)
	test "$_dbg_started" = 'no' && {
		_dbg_started=yes
		_tuish_write '\r'
		_dbg_header
	}
}

_dbg_resize ()
{
	# Redraw header if viewport is established
	if test $TUISH_VIEW_ROWS -gt 0
	then
		tuish_move $((TUISH_VIEW_TOP - 1)) 1
		_dbg_header
	fi
	_dbg_show_event
}

_dbg_show_event ()
{
	_dbg_format_event
	tuish_grow
	_dbg_print_line
}

# ─── Key bindings ───────────────────────────────────────────────────

tuish_bind 'ctrl-w' '_dbg_quit'
tuish_bind 'idle'   '_dbg_idle'
tuish_bind 'resize' '_dbg_resize'
tuish_bind '*'      '_dbg_show_event'

# ─── Main ───────────────────────────────────────────────────────────

tuish_init
tuish_kitty_on || :
tuish_mouse_on
tuish_detailed_on
tuish_modkeys_on
tuish_viewport grow "$_dbg_height"
tuish_run || :
tuish_fini
