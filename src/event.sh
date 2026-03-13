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
	if _tuish_get_byte -t0 && _tuish_get_byte
	then
		_tuish_pending_byte="$_tuish_byte"
		return 0
	fi
	return 1
}

# ─── Stubs (overridden by hid.sh, viewport.sh, keybind.sh) ───────

_tuish_resolve_event ()    { :; }
_tuish_viewport_on_resize () { :; }
tuish_dispatch ()          { return 1; }

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
		if test "${_tuish_raf_inhibit:-0}" -eq 0 && _tuish_get_byte -t0 && _tuish_get_byte
		then
			# More input queued — save byte, skip render
			_tuish_pending_byte="$_tuish_byte"
		else
			# Input exhausted — render now
			_tuish_redraw_requested=0
			local _level=$_tuish_redraw_level
			_tuish_redraw_level=0
			_tuish_buffering=1
			_tuish_buf='\033[?25l'
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
			# Save companion byte (zsh returns it alongside signal);
			# inhibit rAF input check to protect escape sequences.
			local _sig_byte="$_tuish_byte"
			_tuish_raf_inhibit=1
			_tuish_parse_event "S $_sig"
			_tuish_raf_inhibit=0
			_tuish_byte="$_sig_byte"
			# If read timed out / failed, no byte to process
			if test "${_tuish_noinput:-no}" = "yes"
			then
				_tuish_noinput=no
				continue
			fi
			# A byte was read alongside the signal; fall through
			# to process it
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
				elif test "${_tuish_byte}" = 'u' && test "${_esc}" != "${_esc#91}"
				then
					# CSI u (kitty keyboard protocol)
					local _ku_str=''
					local _ku_codes="${_esc#91 }"
					local _ku_c
					for _ku_c in $_ku_codes
					do
						case "$_ku_c" in
							59) _ku_str="${_ku_str};";;
							58) _ku_str="${_ku_str}:";;
							*)  eval "_ku_str=\"\${_ku_str}\$_tuish_chr_$_ku_c\"";;
						esac
					done
					_tuish_parse_event "K ${_ku_str}"
					continue 2
				fi

				_tuish_ord "${_tuish_byte}"

				if test "$_tuish_code" -eq 27
				then
					if test -n "$_esc"
					then
						case "${_esc}" in
							91*|' 79'*) _tuish_parse_event "E ${_esc}";;
							*) _tuish_parse_event "E 27${_esc}";;
						esac
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
					case "${_esc}" in
						91*|' 79'*) _tuish_parse_event "E ${_esc}";;
						*) _tuish_parse_event "E 27${_esc}";;
					esac
					_esc=''
					_tuish_dump_code
					continue 2
				fi

				_esc="${_esc} ${_tuish_code}"
			done
			case "${_esc}" in
				''|91*|' 79'*) _tuish_parse_event "E ${_esc}";;
				*) _tuish_parse_event "E 27${_esc}";;
			esac
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
