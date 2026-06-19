# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/event.sh - Event loop, dispatch, and redraw scheduling
# Optional module. Source after tui.sh.
#
# Provides:
#   tuish_run              - main event loop
#   tuish_start            - convenience: init + run + fini
#   tuish_request_redraw   - schedule deferred redraw (rAF pattern)
#   tuish_cancel_redraw    - cancel pending redraw
#   tuish_has_pending_input - check if input is queued
#   tuish_on_redraw        - callback stub (override in your app)
#   tuish_on_event         - default: calls tuish_dispatch (override for custom logic)
#
# Internal:
#   _tuish_parse_event     - dispatch wrapper (delegates to _tuish_resolve_event)
#   _tuish_dump_code       - route raw byte to parse_event
#   _tuish_kitty_decode    - decode kitty CSI-u ords into the parameter string

if test -n "${_tuish_event_loaded:-}"; then return 0; fi
_tuish_event_loaded=1

# ─── Redraw scheduling ────────────────────────────────────────────

_tuish_redraw_requested=0
_tuish_redraw_level=0
_tuish_raf_inhibit=0

tuish_request_redraw ()
{
	local _level=${1:--1}
	test "$_level" -eq 0 && return
	if test "$_level" -eq -1 || test "$_tuish_redraw_level" -eq -1
	then
		_tuish_redraw_level=-1
	elif test "$_level" -gt "$_tuish_redraw_level"
	then
		_tuish_redraw_level=$_level
	fi
	_tuish_redraw_requested=1
}
tuish_cancel_redraw ()
{
	_tuish_redraw_requested=0
	_tuish_redraw_level=0
}
tuish_on_redraw ()        { :; }

tuish_has_pending_input ()
{
	test -n "${_tuish_pending_byte}" && return 0
	if _tuish_peek_byte
	then
		_tuish_pending_byte="$_tuish_byte"
		return 0
	fi
	return 1
}

# _tuish_resolve_event, _tuish_viewport_on_resize and tuish_dispatch are stubbed
# in tui.sh (the base) and overridden by hid.sh / viewport.sh / keybind.sh.

# ─── Default event handler (override in your app if needed) ──────

tuish_on_event ()          { tuish_dispatch || :; }

# ─── Internal: event dispatch ─────────────────────────────────────

_tuish_parse_event ()
{
	set -- ${1}

	local _class=$1
	TUISH_EVENT=''
	TUISH_EVENT_KIND=''
	TUISH_RAW="${*:-}"

	case "$_class" in
		S) TUISH_EVENT_KIND='signal'; TUISH_EVENT="${2}";;
		F) TUISH_EVENT_KIND='idle'; TUISH_EVENT='idle';;
		*) _tuish_resolve_event "$@";;
	esac

	# No event resolved — skip
	test -z "$TUISH_EVENT" && return

	# Drop mouse events when mouse tracking is off
	if test "$TUISH_EVENT_KIND" = 'mouse' && test $_tuish_mouse -eq 0
	then
		return
	fi

	# Drop repeat/release events when detailed mode is off
	if test $_tuish_detailed -eq 0
	then
		case "$TUISH_EVENT" in
			*-rel|*-rep) return;;
		esac
	fi

	# Drop physical modifier key events when modkeys mode is off
	if test $_tuish_modkeys -eq 0
	then
		case "$TUISH_EVENT" in
			*.[lr]) return;;
		esac
	fi

	# Intercept resize for viewport management
	if test -n "$_tuish_view_mode" && test "$TUISH_EVENT" = 'resize'
	then
		_tuish_viewport_on_resize
	fi

	tuish_begin
	tuish_on_event

	if test $_tuish_redraw_requested -eq 1
	then
		# rAF mode: event handler requested deferred redraw
		# Discard any output from the event handler
		_tuish_buf=''
		_tuish_buffering=0
		if test "${_tuish_raf_inhibit:-0}" -eq 1 || tuish_has_pending_input
		then
			# More input in flight — leave the redraw pending. When
			# inhibit is set, the next sequence's ESC byte was already
			# read, so peeking would eat its body; a later dispatch
			# with the peek allowed (burst-final timeout path, or an
			# idle event) fires the redraw.
			:
		else
			# Input exhausted — render now
			_tuish_redraw_requested=0
			local _level=$_tuish_redraw_level
			_tuish_redraw_level=0
			_tuish_buffering=1
			_tuish_buf=''
			tuish_hide_cursor
			_tuish_cursor_vrow=0
			tuish_on_redraw "$_level"
			test -n "$_tuish_buf" && _tuish_out "$_tuish_buf"
			_tuish_buf=''
			_tuish_buffering=0
		fi
	else
		tuish_end
	fi
}

# ─── Internal: byte-to-event loop ──────────────────────────────────

# Decode kitty CSI-u byte codes (space-separated ords) into the parameter
# string. Result in _tuish_ku_str.
#
# INVARIANT: tuish_run must contain no `for`/iteration construct that leaves a
# control variable set in its own frame. Under zsh, a loop-control variable
# still live in the main loop's frame when the next read-then-render fires (the
# burst race) gets echoed to the terminal — the `_ku_c=51` screen leak. Plain
# live locals (_esc, _sig) do NOT leak: they are equally in scope at the
# legacy-escape and kitty dispatches yet never echoed, so the defect is the
# loop variable specifically. This decode is therefore kept in its own
# function: _kc dies on return, before any dispatch. tuish_run's remaining
# loops are `while _tuish_get_byte` (no control variable — the byte is the
# global _tuish_byte), which are safe. Keep it that way.
_tuish_kitty_decode ()
{
	local _kc
	_tuish_ku_str=''
	for _kc in $1
	do
		case "$_kc" in
			59) _tuish_ku_str="${_tuish_ku_str};";;
			58) _tuish_ku_str="${_tuish_ku_str}:";;
			*)  eval "_tuish_ku_str=\"\${_tuish_ku_str}\$_tuish_chr_$_kc\"";;
		esac
	done
}

_tuish_dump_code ()
{
	if test $_tuish_code -gt 31 && test $_tuish_code -lt 127
	then
		_tuish_parse_event "C $_tuish_byte"
		return
	elif test $_tuish_code -eq 226
	then
		local _prev="${_tuish_byte}"
		_tuish_get_byte
		_prev="${_prev}${_tuish_byte}"
		_tuish_get_byte
		_tuish_parse_event "C ${_prev}${_tuish_byte}"
		return
	elif test $_tuish_code -eq 194 || test $_tuish_code -eq 195
	then
		local _prev="${_tuish_byte}"
		_tuish_get_byte
		_tuish_parse_event "C ${_prev}${_tuish_byte}"
		return
	else
		_tuish_parse_event "E ${_tuish_code}"
	fi
}

# Dispatch an accumulated escape body $1 (e.g. "91 67" or " 79 65"): a CSI
# ('91…'), SS3 (' 79…'), or bare ESC ('') body emits class E unchanged; any other
# body is an Alt-<key> (ESC + byte), emitted with the 27 (ESC) prefix. Factored
# out of tuish_run's escape-dispatch sites so the CSI/SS3-vs-Alt rule lives in one
# place. A plain function (no loop variable) is safe here — see the
# _tuish_kitty_decode INVARIANT note above.
_tuish_esc_emit ()
{
	case "${1}" in
		''|91*|' 79'*) _tuish_parse_event "E ${1}";;
		*) _tuish_parse_event "E 27${1}";;
	esac
}

tuish_run ()
{
	_tuish_quit=''
	_tuish_quit_mode=''

	# Fire initial idle event so the app can render before waiting for input
	_tuish_parse_event "F"

	while
		test "${_tuish_quit:-}" != yes && {
		test -n "${_tuish_pending_byte}" ||
		_tuish_idle_wait ||
		_tuish_noinput=yes ;}
	do
		if test -n "${_tuish_pending_byte}"
		then
			_tuish_byte="$_tuish_pending_byte"
			_tuish_pending_byte=''
			_tuish_noinput=no
		fi

		if test -n "${_tuish_signal:-}"
		then
			local _sig="$_tuish_signal"
			_tuish_signal=''
			# If read timed out / failed, no byte to process:
			# nothing is in flight, so the rAF peek is safe and
			# signal redraws render immediately
			if test "${_tuish_noinput:-no}" = "yes"
			then
				_tuish_parse_event "S $_sig"
				_tuish_noinput=no
				continue
			fi
			# A companion byte was read alongside the signal (zsh):
			# its sequence body is still unread — inhibit the rAF
			# peek so it can't eat those bytes. The pending redraw
			# fires when the companion byte's own events dispatch.
			local _sig_byte="$_tuish_byte"
			_tuish_raf_inhibit=1
			_tuish_parse_event "S $_sig"
			_tuish_raf_inhibit=0
			_tuish_byte="$_sig_byte"
			# Fall through to process the companion byte
		elif test "${_tuish_noinput:-no}" = "yes"
		then
			_tuish_parse_event "F"
			_tuish_noinput=no
			continue
		fi

		_tuish_ord "${_tuish_byte}"

		if test "$_tuish_code" -eq 27
		then
			local _esc=''
			while _tuish_get_byte "$_tuish_esc_timeout"
			do
				if test "$_esc" = '91' &&
					test "${_tuish_byte}" = '<'
				then
					_esc='M '
					while _tuish_get_byte
					do
						if test "${_tuish_byte}" = ';'
						then
							_esc="${_esc} "
							continue
						elif test "${_tuish_byte}" = 'm'
						then
							# SGR release: use class 'm'
							_esc="m${_esc#M}"
							break
						elif test "${_tuish_byte}" = 'M'
						then
							break
						else
							_esc="${_esc}${_tuish_byte}"
							continue
						fi
					done
					_tuish_parse_event "${_esc}"
					continue 2
				elif
					test "$_esc" = '' &&
					test "$_tuish_byte" = "["
				then
					_esc="91"
					continue
				elif
					test "$_esc" = '' &&
					test "$_tuish_byte" = "O"
				then
					# SS3 introducer (ESC O): the next byte is the final. Mark the
					# state so the final-byte check below doesn't fire on the 'O'.
					_esc=" 79"
					continue
				elif test "${_tuish_byte}" = 'u' && test "${_esc}" != "${_esc#91}"
				then
					# CSI u (kitty keyboard protocol)
					_tuish_kitty_decode "${_esc#91 }"
					_tuish_parse_event "K ${_tuish_ku_str}"
					continue 2
				fi

				_tuish_ord "${_tuish_byte}"

				if test "$_tuish_code" -eq 27
				then
					if test -n "$_esc"
					then
						# Inhibit rAF input-peek: the inner loop still needs to read
						# the bytes that follow this ESC (next sequence's O, C, etc.).
						# The rAF check defers the redraw instead of peeking; the
						# burst-final sequence (timeout path below) fires it.
						_tuish_raf_inhibit=1
						_tuish_esc_emit "$_esc"
						_tuish_raf_inhibit=0
					fi
					_esc=''
					continue
				elif test "$_tuish_code" -lt 32
				then
					if test -z "$_esc"
					then
						_tuish_parse_event "E 27 ${_tuish_code}"
						continue 2
					fi
					_tuish_esc_emit "$_esc"
					_esc=''
					_tuish_dump_code
					continue 2
				fi

				_esc="${_esc} ${_tuish_code}"

				# A CSI/SS3 final byte (0x40-0x7E) ends the sequence: dispatch now
				# instead of waiting out _tuish_esc_timeout for a continuation that
				# is not coming. Parameter/intermediate bytes are all < 0x40, so the
				# first byte >= 0x40 after the introducer is the final one. (Mouse
				# '<…M/m' and kitty '…u' already break above; the 91*/' 79'* guard
				# keeps Alt-<key> — ESC with no introducer — on the timeout path.)
				# This makes cursor/function keys instant and stops a held arrow's
				# autorepeat from starving idle events.
				if test "$_tuish_code" -ge 64 && test "$_tuish_code" -le 126
				then
					case "${_esc}" in
						91*|' 79'*) _tuish_parse_event "E ${_esc}"; continue 2;;
					esac
				fi
			done
			_tuish_esc_emit "$_esc"
			continue
		fi

		_tuish_dump_code
	done
}

tuish_start ()
{
	tuish_init
	tuish_run || :
	tuish_fini
}
