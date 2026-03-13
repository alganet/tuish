#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/tui.sh - Terminal UI core: setup, teardown, traps, IO stubs
# Source compat.sh and ord.sh first, then this file.  Do not execute directly.
#
# Provides:
#   tuish_init             - set up terminal for TUI (raw mode, protocol detection)
#   tuish_fini             - restore terminal to previous state
#   tuish_quit             - signal event loop to stop
#   tuish_quit_main        - quit, leave viewport content visible, cursor below
#   tuish_quit_clear       - quit, clear viewport, restore cursor position
#   tuish_update_size      - refresh TUISH_LINES / TUISH_COLUMNS
#   tuish_begin            - start output buffering
#   tuish_end              - flush buffer and stop buffering
#   tuish_flush            - flush buffer (keep buffering active)
#   tuish_show_cursor      - show cursor
#   tuish_hide_cursor      - hide cursor
#   tuish_save_cursor      - save cursor position (DECSC)
#   tuish_restore_cursor   - restore cursor position (DECRC)
#   tuish_reset_scroll     - reset scroll region to full screen
#
# Variables (set after tuish_init):
#   TUISH_LINES            - terminal height
#   TUISH_COLUMNS          - terminal width
#   TUISH_INIT_ROW         - cursor row when init was called
#   TUISH_PROTOCOL         - keyboard protocol: "vt" or "kitty"
#   TUISH_TIMING           - timeout resolution: "sub" or "second"
#
# Configuration (set before tuish_init):
#   TUISH_TABSIZE          - tab stop interval (default: 4)
#   TUISH_FINI_OFFSET      - lines below init position to place cursor after fini (default: 0)
#   TUISH_IDLE_TIMEOUT     - idle event interval in seconds (default: 0.26, or 1 for second timing)

# ─── Dependencies ─────────────────────────────────────────────────
# Source compat.sh before this file.  It provides:
#   _tuish_printf, _tuish_out(), alias local=typeset (ksh93)

# ─── IO stubs (overridden by term.sh) ────────────────────────────
# Minimal buffered-write and cursor primitives used by init/fini
# and event.sh.  term.sh redefines these with the same behavior
# plus full drawing primitives, colors, and style.

_tuish_buf=''
_tuish_buffering=0
_tuish_clipped=0

_tuish_write ()
{
	test $_tuish_clipped -eq 1 && return
	if test $_tuish_buffering -eq 1
	then
		_tuish_buf="${_tuish_buf}${1:-}"
	else
		_tuish_out "${1:-}"
	fi
}

tuish_begin ()          { _tuish_clipped=0; _tuish_buffering=1; _tuish_buf=''; }
tuish_end ()            { test -n "$_tuish_buf" && _tuish_out "$_tuish_buf"; _tuish_buf=''; _tuish_buffering=0; }
tuish_flush ()          { test -n "$_tuish_buf" && _tuish_out "$_tuish_buf"; _tuish_buf=''; }

tuish_save_cursor ()    { _tuish_write '\x1b7'; }
tuish_restore_cursor () { _tuish_write '\0338'; }
tuish_show_cursor ()    { _tuish_write '\033[?25h'; }
tuish_hide_cursor ()    { _tuish_write '\033[?25l'; }
tuish_cursor ()         { :; }
tuish_reset_scroll ()   { _tuish_write '\033[;r'; }

# ─── HID state defaults ──────────────────────────────────────────
# These are referenced by event.sh (filtering) and tuish_fini.
# Toggle functions are provided by hid.sh.

_tuish_mouse=0
_tuish_detailed=0
_tuish_modkeys=0
_tuish_wrap=0
_tuish_kitty_raw='letter'

# ─── Control ────────────────────────────────────────────────────────

_tuish_quit=''
_tuish_quit_mode=''

tuish_quit ()       { _tuish_quit=yes; _tuish_quit_mode=''; }
tuish_quit_main ()  { _tuish_quit=yes; _tuish_quit_mode=main; }
tuish_quit_clear () { _tuish_quit=yes; _tuish_quit_mode=clear; }

# ─── Internal state ─────────────────────────────────────────────────

_tuish_byte=''
_tuish_signal=''
_tuish_precols=''
_tuish_previous_stty=''
_tuish_stty=''
_tuish_esc_timeout=''
_tuish_idle_timeout=''
_tuish_pending_byte=''
_tuish_initialized=0

# Default byte reader (overridden by tuish_init with shell-specific version)
_tuish_get_byte () { return 1; }
_tuish_idle_wait () { return 1; }

TUISH_EVENT=''
TUISH_EVENT_KIND=''
TUISH_MOUSE_X=0
TUISH_MOUSE_Y=0
TUISH_RAW=''
TUISH_LINES=0
TUISH_COLUMNS=0
TUISH_INIT_ROW=0
_tuish_cursor_abs_row=0
_tuish_cursor_vrow=0
_tuish_cursor_vcol=0
TUISH_PROTOCOL=''
TUISH_TIMING=''
TUISH_TABSIZE="${TUISH_TABSIZE:-4}"
TUISH_FINI_OFFSET="${TUISH_FINI_OFFSET:-0}"
TUISH_MOUSE_ABS_Y=0

# ─── Viewport defaults ───────────────────────────────────────────
# TUISH_VIEW_TOP=1 so tuish_vmove works even without viewport.sh.

TUISH_VIEW_MODE=''
TUISH_VIEW_ROWS=0
TUISH_VIEW_COLS=0
TUISH_VIEW_TOP=1

_tuish_view_mode=''
_tuish_fini_push_gap=0
_tuish_on_fini () { :; }

# ─── Size management ────────────────────────────────────────────────

tuish_update_size ()
{
	local _ts
	_ts="$(stty size)"
	TUISH_LINES="${_ts% *}"
	TUISH_COLUMNS="${_ts#* }"
}

# ─── Lifecycle ──────────────────────────────────────────────────────

tuish_init ()
{
	# Detect byte-reading capability
	if { echo 1 | read -s -k1 -u0 2>/dev/null ;}
	then
		_tuish_get_byte ()
		{
			IFS= read -r -k1 -u0 ${@:-} _tuish_byte 2>/dev/null || return 1
		}
		# zsh defers signals during builtins; force delivery
		# via subshell fork after polling.
		_tuish_idle_wait ()
		{
			local _i=0
			while test $_i -lt 9
			do
				IFS= read -r -k1 -u0 -t0.03 _tuish_byte 2>/dev/null && return 0
				_i=$((_i + 1))
			done
			eval "$(:)" 2>/dev/null
			test -n "${_tuish_signal:-}" && return 1
			return 1
		}
	elif { echo 1 | read -r -t'0.1' -n 1 2>/dev/null ;}
	then
		_tuish_get_byte ()
		{
			IFS= read -r -d '' -n 1 ${@:-} _tuish_byte 2>/dev/null || return 1
		}
		_tuish_idle_wait ()
		{
			_tuish_get_byte "$_tuish_idle_timeout"
		}
	else
		echo 'Shell does not support interactive features (requires read -n or read -k)' 1>&2
		return 1
	fi

	# Detect timeout resolution
	TUISH_TIMING='second'
	if { echo 1 | read -r -t'0.01' -n 1 2>/dev/null ;} ||
	   { echo 1 | read -r -t'0.01' -k1 -u0 2>/dev/null ;}
	then
		TUISH_TIMING='sub'
	fi

	_tuish_esc_timeout='-t0.02'
	_tuish_idle_timeout="-t${TUISH_IDLE_TIMEOUT:-0.26}"
	if test "$TUISH_TIMING" = 'second'
	then
		_tuish_esc_timeout='-t1'
		_tuish_idle_timeout="-t${TUISH_IDLE_TIMEOUT:-1}"
	fi

	_tuish_code=''
	_tuish_held=''
	_tuish_noinput=''

	# Save and configure terminal
	_tuish_previous_stty="$(stty -g)"
	_tuish_initialized=1
	trap '[ "${BASH_SUBSHELL:-${ZSH_SUBSHELL:-0}}" -eq 0 ] && tuish_fini' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	stty raw -echo -ctlecho -isig -icanon -ixon -ixoff -tostop -ocrnl \
		-icrnl -inlcr -igncr \
		intr undef quit undef werase undef discard undef time 0 2>/dev/null
	_tuish_stty="$(stty -g)"

	trap '_tuish_signal=resize; _tuish_precols=$TUISH_COLUMNS' WINCH 2>/dev/null || :
	trap ':' TSTP 2>/dev/null || :
	trap '_tuish_signal=cont; stty "$_tuish_stty"' CONT 2>/dev/null || :

	# Terminal setup sequences
	tuish_save_cursor
	_tuish_write '\033[?2004h\033[2K'   # bracketed paste, clear line
	_tuish_write '\033[22;0;0t'          # push title
	_tuish_write '\033[?1h'              # application cursor keys
	_tuish_write '\033[?20l'             # LNM reset
	tuish_hide_cursor

	# Get terminal size and cursor position
	tuish_update_size
	local _newx=0 _newy=0
	_tuish_write '\033[6n\r'
	IFS='[;' read -r -d R _ _newx _newy 2>/dev/null || :
	TUISH_INIT_ROW=$_newx

	# Focus events (mouse tracking is off by default; use tuish_mouse_on)
	_tuish_write '\033[?1004h'   # focus events
	_tuish_write '\033[777h'     # ambiguous width
	_tuish_write '\033[?7l'      # DECAWM off: clip at right edge

	TUISH_PROTOCOL='vt'

	# Set tab stops
	_tuish_write '\033[3g'
	local _tcont=0
	while test $_tcont -lt ${TUISH_COLUMNS}
	do
		_tuish_write '\033['"${TUISH_TABSIZE}"'C\033H'
		_tcont=$((_tcont + TUISH_TABSIZE))
	done
	_tuish_write '\r'
}

tuish_fini ()
{
	# Idempotent: safe to call from both explicit call and EXIT trap
	test "$_tuish_initialized" -eq 0 && return 0
	_tuish_initialized=0
	trap - EXIT INT TERM HUP 2>/dev/null || :
	trap - WINCH TSTP CONT 2>/dev/null || :

	# Bypass buffering so cleanup sequences reach the terminal
	_tuish_buffering=0
	_tuish_buf=''
	_tuish_clipped=0

	# Hide cursor during cleanup to avoid flicker
	tuish_hide_cursor

	# Viewport teardown
	_tuish_fini_push_gap=0
	_tuish_on_fini

	# Restore keyboard protocol
	if test "$TUISH_PROTOCOL" = 'kitty'
	then
		_tuish_write '\033[<u'
		_tuish_write '\033[>0u'
		TUISH_PROTOCOL='vt'
	fi

	# Restore terminal
	tuish_reset_scroll
	if test $_tuish_mouse -eq 1
	then
		_tuish_write '\033[?1006l'   # SGR mouse off
		_tuish_write '\033[?1003l'   # any event tracking off
		_tuish_write '\033[?1002l'   # button event tracking off
		_tuish_mouse=0
	fi
	_tuish_write '\033[?1004l'   # focus events off
	_tuish_write '\033[777l'
	_tuish_write '\033[?2004l'   # bracketed paste off
	_tuish_write '\033[?7h'      # DECAWM on: restore auto-wrap
	_tuish_write '\033[?1l'      # normal cursor keys
	_tuish_write '\033>'         # normal keypad
	tuish_restore_cursor
	if test "${TUISH_FINI_OFFSET:-0}" -gt 0
	then
		_tuish_write '\033['"${TUISH_FINI_OFFSET}"'B'
	fi
	# Move cursor up past empty space left by viewport push
	if test $_tuish_fini_push_gap -gt 0 && test "$_tuish_quit_mode" != 'main'
	then
		_tuish_write '\033['"$_tuish_fini_push_gap"'A'
	fi
	_tuish_write '\033[?20h'     # LNM set
	_tuish_write '\033[23;0;0t'  # pop title
	_tuish_write '\033[0 q'   # DECSCUSR: restore default cursor shape
	tuish_show_cursor

	# Restore stty
	stty "${_tuish_previous_stty:-}" 2>/dev/null || :
	stty sane echo icanon 2>/dev/null || :

	# Drain stdin
	while read -r -t'0.1' 2>/dev/null
	do
		:
	done

	if test "$_tuish_quit_mode" = 'main'
	then
		# Position cursor below last content row
		test $_tuish_fini_push_gap -gt 0 && _tuish_write '\n' || :
	else
		_tuish_write '\r\033[2K'
	fi
}
