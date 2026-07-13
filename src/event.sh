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

# The redraw scheduler is per-context (a nested child renders on its own clock).
tuish_ctx_register _tuish_redraw_requested _tuish_redraw_level _tuish_raf_inhibit

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

# ─── Render / event handlers, referenced by name per context ─────
# A context stores the NAME of its render/event handler (not a redefined global
# function), so multiple apps can coexist and be saved/restored without any
# function-body introspection (busybox has none). The framework calls the active
# context's handler indirectly, falling back to the redefinable tuish_on_redraw /
# tuish_on_event stubs when no name was registered — so the classic "redefine the
# hook" style keeps working unchanged for a single-context app.
_tuish_render_fn=''
_tuish_event_fn=''
command -v tuish_ctx_register >/dev/null 2>&1 && tuish_ctx_register _tuish_render_fn _tuish_event_fn

# tuish_on_redraw is polymorphic:
#   tuish_on_redraw FUNC   (arg contains a non-digit) -> register FUNC as the
#                          active context's render handler (the hostable form).
#   tuish_on_redraw LEVEL  (empty or numeric, i.e. the framework's fallback call
#                          when nothing was registered) -> no-op default.
# An app may instead redefine this function outright; then it is never called as
# a setter (the fallback simply invokes the redefined body).
tuish_on_redraw ()
{
	case "${1:-}" in
		*[!0-9-]*) _tuish_render_fn="$1";;
		*) : ;;
	esac
}

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
# Polymorphic like tuish_on_redraw:
#   tuish_on_event FUNC  (one arg) -> register FUNC as the active context's event
#                        handler (the hostable form).
#   tuish_on_event       (no arg, the framework's fallback call) -> the default
#                        behavior: dispatch the event through the bindings.
tuish_on_event ()
{
	if test $# -gt 0
	then _tuish_event_fn="$1"
	else tuish_dispatch || :
	fi
}

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

	# MODAL hosting only: a click outside our region is meant for the host, not us,
	# but a modal child owns the keyboard inside its own nested tuish_run — so the
	# only way to hand control back is to end that loop. We quit; the host's
	# tuish_run resumes and its UI is live again. The click itself is CONSUMED, not
	# replayed: closing the child IS the response to it. Motion outside is ignored.
	#
	# A cooperatively-driven child (_tuish_driven) never takes this path: its host
	# keeps the one loop and routes by region, forwarding only what falls inside —
	# so an outside click simply never reaches the child, and self-quitting here
	# would be a spurious quit the host would read as "the app ended".
	if test "${_tuish_hosted:-0}" -eq 1 && test "${_tuish_driven:-0}" -ne 1 \
	   && test "$TUISH_EVENT_KIND" = 'mouse'
	then
		case "$TUISH_EVENT" in
			*clik)
				if test "$TUISH_MOUSE_X" -lt 1 || test "$TUISH_MOUSE_X" -gt "$_tuish_rgn_cols" \
				   || test "$TUISH_MOUSE_Y" -lt 1 || test "$TUISH_MOUSE_Y" -gt "$_tuish_rgn_rows"
				then
					tuish_quit
					return
				fi
				;;
		esac
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
	"${_tuish_event_fn:-tuish_on_event}"

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
			"${_tuish_render_fn:-tuish_on_redraw}" "$_level"
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
				elif test "$_esc" = '91' && test "${_tuish_byte}" = 'M'
				then
					# X10 mouse (ESC [ M cb cx cy): the fallback for a terminal
					# without SGR-mouse (1006). The three bytes are button/x/y, each
					# offset by 32. Consume them HERE — otherwise the final-byte
					# dispatch below fires on 'M' (0x4D, a CSI final) and the three
					# coordinate bytes leak out as spurious keystrokes. cb-32 is the
					# same button encoding SGR sends, so it resolves via the same
					# M-class path. Reads are esc-timeout-bounded so a truncated
					# report can't hang the loop.
					local _x10n=0 _x10b='' _x10x='' _x10y=''
					while test $_x10n -lt 3
					do
						_tuish_get_byte "$_tuish_esc_timeout" || break
						_tuish_ord "${_tuish_byte}"
						case $_x10n in
							0) _x10b=$((_tuish_code - 32));;
							1) _x10x=$((_tuish_code - 32));;
							2) _x10y=$((_tuish_code - 32));;
						esac
						_x10n=$((_x10n + 1))
					done
					test $_x10n -eq 3 && \
						_tuish_parse_event "M ${_x10b} ${_x10x} ${_x10y}"
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
