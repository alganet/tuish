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
#   TUISH_TICK_US          - idle interval in microseconds (for time-based animation)
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

# DECSC/DECRC are ESC followed by a digit. Emit a literal ESC byte (from
# the ord table) rather than a backslash escape, because no single escape
# form survives every shell's printf/echo: `\x1b7` reads as hex 0x1b7 on
# ksh93, and `\0337` reads as octal 337 on mksh — both swallow the digit.
tuish_save_cursor ()    { _tuish_write "${_tuish_chr_27}7"; }
tuish_restore_cursor () { _tuish_write "${_tuish_chr_27}8"; }
tuish_show_cursor ()    { _tuish_write '\033[?25h'; }
tuish_hide_cursor ()    { _tuish_write '\033[?25l'; }
tuish_cursor ()         { :; }
tuish_reset_scroll ()   { _tuish_write '\033[r'; }

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
_tuish_idle_chunk='-t0.03'
_tuish_idle_chunks=1
_tuish_pending_byte=''
_tuish_initialized=0

# Default byte reader (overridden by tuish_init with shell-specific version)
_tuish_get_byte () { return 1; }
_tuish_idle_wait () { return 1; }
_tuish_peek_byte () { return 1; }

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

# ─── Timeout parsing ─────────────────────────────────────────────────
# _tuish_timeout_us TIMEOUT -> _tuish_tick_us
# Convert a seconds timeout string ("0.02", "0.26", "1", "0.5") to integer
# microseconds. The single parser behind both TUISH_TICK_US (animation clock)
# and the zsh idle-chunk count. Fractional part is read to 6 digits (µs); the
# whole and fraction are forced base-10 (10#) so leading-zero fractions like
# "020" are not misread as octal. Zero/empty falls back to ~60 Hz.
_tuish_timeout_us ()
{
	case "$1" in
		*.*) local _w="${1%.*}" _f="${1#*.}000000"
		     _f="${_f%"${_f#??????}"}"
		     _tuish_tick_us=$(( ${_w:-0} * 1000000 + 10#$_f ));;
		*)   _tuish_tick_us=$(( ${1:-0} * 1000000 ));;
	esac
	test "$_tuish_tick_us" -le 0 && _tuish_tick_us=16667
	return 0
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
		# Poll for input up to TUISH_IDLE_TIMEOUT, in <=30ms chunks: zsh defers
		# signals (traps) inside the read builtin, so each chunk boundary is a
		# delivery point and the trailing subshell fork forces any pending trap
		# to run. The chunk COUNT is derived from TUISH_IDLE_TIMEOUT in init
		# (_tuish_idle_chunks/_tuish_idle_chunk), so the idle interval honors the
		# configured timeout instead of a fixed 270ms.
		_tuish_idle_wait ()
		{
			local _i=$_tuish_idle_chunks
			while test $_i -gt 0
			do
				IFS= read -r -k1 -u0 $_tuish_idle_chunk _tuish_byte 2>/dev/null && return 0
				_i=$((_i - 1))
			done
			eval "$(:)" 2>/dev/null
			test -n "${_tuish_signal:-}" && return 1
			return 1
		}
		# zsh read -t0 reads a byte when one is available (unlike bash which
		# only checks). One call is enough to peek at the next pending byte.
		_tuish_peek_byte () { _tuish_get_byte -t0; }
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
		# read -t0 semantics differ: bash/busybox only check availability
		# and need a second read to consume; ksh93/mksh consume the byte
		# on the spot (like zsh). Assuming the wrong one either loses
		# every other byte and blocks mid-burst (ksh93/mksh) or leaks
		# sequence bytes (zsh, see 258e6a4).
		#
		# ksh93 and mksh both set KSH_VERSION and both consume on -t0, so
		# select by shell identity. A runtime probe is unreliable here:
		# mksh's own `read -d '' -n 1 -t0` on a heredoc is non-deterministic
		# (it intermittently reports no data), which would sometimes pick the
		# two-read variant and then drop one byte on every peek that finds
		# input — the source of mksh's burst-event flakiness.
		if test -n "${KSH_VERSION:-}"
		then
			_tuish_peek_byte () { _tuish_get_byte -t0; }
		else
			# bash/busybox: probe with a heredoc — its data is in place
			# before read runs, so a zero timeout can't race the writer
			# the way a pipeline would. (Stable: both report no data, so
			# both take the two-read consume path.)
			_tuish_probe=''
			if { IFS= read -r -d '' -n 1 -t0 _tuish_probe 2>/dev/null &&
				test -n "${_tuish_probe}" ;} <<_tuish_heredoc
1
_tuish_heredoc
			then
				_tuish_peek_byte () { _tuish_get_byte -t0; }
			else
				_tuish_peek_byte () { _tuish_get_byte -t0 && _tuish_get_byte; }
			fi
		fi
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
	_tuish_idle_default='0.26'
	if test "$TUISH_TIMING" = 'second'
	then
		_tuish_esc_timeout='-t1'
		_tuish_idle_timeout="-t${TUISH_IDLE_TIMEOUT:-1}"
		_tuish_idle_default='1'
	fi

	# The idle interval in microseconds: the wall-time one idle tick spans, for
	# time-based animation. Single source for the zsh idle-chunk math below.
	_tuish_timeout_us "${TUISH_IDLE_TIMEOUT:-$_tuish_idle_default}"
	TUISH_TICK_US=$_tuish_tick_us

	# Chunked idle wait (zsh): poll in slices of at most 30ms up to the full
	# idle timeout, so the idle interval tracks TUISH_IDLE_TIMEOUT. One read of
	# the whole timeout when it's already <=30ms; otherwise ceil(timeout/30ms)
	# slices of 30ms (default 0.26s -> 9 slices, the historical interval).
	_tuish_idle_chunk="$_tuish_idle_timeout"
	_tuish_idle_chunks=1
	if test "$TUISH_TIMING" != 'second'
	then
		_itms=$(( TUISH_TICK_US / 1000 ))
		if test "$_itms" -gt 30
		then
			_tuish_idle_chunk='-t0.03'
			_tuish_idle_chunks=$(( (_itms + 29) / 30 ))
		fi
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
	_tuish_write '\033[20l'              # LNM (ANSI mode 20) reset for the TUI
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
	_tuish_write '\033[?1l'      # normal cursor keys
	_tuish_write '\033>'         # normal keypad
	tuish_restore_cursor
	# DECAWM must be restored AFTER DECRC (tuish_restore_cursor): the viewport
	# teardown's DECSC saved cursor state while autowrap was off (init sets
	# \033[?7l), and on conpty/Windows Terminal DECRC restores DECAWM to that
	# saved-off value — reverting an earlier \033[?7h. (xterm/tmux don't, which
	# is why this only bit some terminals.) Re-assert it here, last.
	_tuish_write '\033[?7h'      # DECAWM on: restore auto-wrap
	if test "${TUISH_FINI_OFFSET:-0}" -gt 0
	then
		_tuish_write '\033['"${TUISH_FINI_OFFSET}"'B'
	fi
	# Move cursor up past empty space left by viewport push
	if test $_tuish_fini_push_gap -gt 0 && test "$_tuish_quit_mode" != 'main'
	then
		_tuish_write '\033['"$_tuish_fini_push_gap"'A'
	fi
	_tuish_write '\033[20h'      # LNM (ANSI mode 20) set: restore newline mode
	_tuish_write '\033[23;0;0t'  # pop title
	_tuish_write '\033[0 q'   # DECSCUSR: restore default cursor shape
	tuish_show_cursor

	# Restore stty: prefer the exact saved state so a faithful snapshot
	# (e.g. IUTF8, and any terminal-specific flags) is preserved. Fall back
	# to sane only if we never captured one (init aborted) or the restore
	# fails — otherwise `stty sane` clobbers the just-restored original.
	if test -n "${_tuish_previous_stty:-}" && stty "$_tuish_previous_stty" 2>/dev/null
	then :
	else stty sane echo icanon 2>/dev/null || :
	fi

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
