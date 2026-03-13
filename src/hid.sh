# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/hid.sh - Human interface device: keyboard/mouse event resolution
# Optional module. Source after event.sh.
#
# Provides:
#   tuish_kitty_on/off      - enable/disable kitty keyboard protocol
#   tuish_mouse_on/off      - enable/disable mouse tracking
#   tuish_detailed_on/off   - enable/disable press/release/repeat reporting
#   tuish_modkeys_on/off    - enable/disable physical modifier key events
#   tuish_wrap_on/off       - enable/disable auto-wrap (DECAWM)
#
# Internal:
#   _tuish_resolve_event    - overrides event.sh stub with full resolution
#   _tuish_5code_modifiers  - VT 5-code modifier helper
#   _tuish_6code_modifiers  - VT 6-code modifier helper

# ─── HID state ────────────────────────────────────────────────────
# _tuish_kitty_raw, _tuish_mouse, _tuish_detailed, _tuish_modkeys,
# _tuish_wrap are initialized in tui.sh (HID state defaults).

_tuish_held=''

# ─── Keyboard protocol ──────────────────────────────────────────

tuish_kitty_on ()
{
	test "$TUISH_PROTOCOL" = 'kitty' && return 0
	# Probe kitty protocol; skip non-matching CSI sequences
	_tuish_out '\033[?u'
	while _tuish_get_byte "$_tuish_esc_timeout"
	do
		_tuish_ord "$_tuish_byte"
		if test "$_tuish_code" -ne 27
		then
			_tuish_pending_byte="$_tuish_byte"
			return 1
		fi
		_tuish_get_byte "$_tuish_esc_timeout" || return 1
		test "$_tuish_byte" != '[' && return 1
		_tuish_get_byte "$_tuish_esc_timeout" || return 1
		if test "$_tuish_byte" = '?'
		then
			while _tuish_get_byte "$_tuish_esc_timeout"
			do
				test "$_tuish_byte" = 'u' && break
			done
			_tuish_write '\033[>9u'
			TUISH_PROTOCOL='kitty'
			return 0
		fi
		# Not the probe response — skip to end of this CSI sequence
		_tuish_ord "$_tuish_byte"
		while test "$_tuish_code" -lt 64 || test "$_tuish_code" -gt 126
		do
			_tuish_get_byte "$_tuish_esc_timeout" || return 1
			_tuish_ord "$_tuish_byte"
		done
	done
	return 1
}

tuish_kitty_off ()
{
	test "$TUISH_PROTOCOL" != 'kitty' && return 0
	_tuish_write '\033[<u'
	_tuish_write '\033[>0u'
	TUISH_PROTOCOL='vt'
	_tuish_kitty_raw='letter'
}

# ─── Event tracking toggles ──────────────────────────────────────

tuish_mouse_on ()
{
	_tuish_mouse=1
	_tuish_write '\033[?1002h'   # button event tracking
	_tuish_write '\033[?1003h'   # any event tracking
	_tuish_write '\033[?1006h'   # SGR mouse mode
}

tuish_mouse_off ()
{
	_tuish_write '\033[?1006l'   # SGR mouse off
	_tuish_write '\033[?1003l'   # any event tracking off
	_tuish_write '\033[?1002l'   # button event tracking off
	_tuish_mouse=0
}

tuish_detailed_on ()
{
	_tuish_detailed=1
	if test "$TUISH_PROTOCOL" = 'kitty'
	then
		_tuish_write '\033[=11u'
	fi
}

tuish_detailed_off ()
{
	if test "$TUISH_PROTOCOL" = 'kitty'
	then
		_tuish_write '\033[=9u'
	fi
	_tuish_detailed=0
}

tuish_modkeys_on ()
{
	_tuish_modkeys=1
}

tuish_modkeys_off ()
{
	_tuish_modkeys=0
}

tuish_wrap_on ()
{
	_tuish_write '\033[?7h'   # DECAWM on: enable auto-wrap
	_tuish_wrap=1
}

tuish_wrap_off ()
{
	_tuish_write '\033[?7l'   # DECAWM off: disable auto-wrap (clip)
	_tuish_wrap=0
}

# ─── Internal: modifier helpers ─────────────────────────────────────

_tuish_5code_modifiers ()
{
	case "${1}" in
		"91 ${2} 59 49 ${4}" ) TUISH_EVENT="${3}";;
		"91 ${2} 59 50 ${4}" ) TUISH_EVENT="shift-${3}";;
		"91 ${2} 59 51 ${4}" ) TUISH_EVENT="alt-${3}";;
		"91 ${2} 59 52 ${4}" ) TUISH_EVENT="alt-shift-${3}";;
		"91 ${2} 59 53 ${4}" ) TUISH_EVENT="ctrl-${3}";;
		"91 ${2} 59 54 ${4}" ) TUISH_EVENT="ctrl-shift-${3}";;
		"91 ${2} 59 55 ${4}" ) TUISH_EVENT="ctrl-alt-${3}";;
		"91 ${2} 59 56 ${4}" ) TUISH_EVENT="ctrl-alt-shift-${3}";;
	esac
}

_tuish_6code_modifiers ()
{
	case "${1}" in
		"91 ${2} ${4} 59 49 126" ) TUISH_EVENT="${3}";;
		"91 ${2} ${4} 59 50 126" ) TUISH_EVENT="shift-${3}";;
		"91 ${2} ${4} 59 51 126" ) TUISH_EVENT="alt-${3}";;
		"91 ${2} ${4} 59 52 126" ) TUISH_EVENT="alt-shift-${3}";;
		"91 ${2} ${4} 59 53 126" ) TUISH_EVENT="ctrl-${3}";;
		"91 ${2} ${4} 59 54 126" ) TUISH_EVENT="ctrl-shift-${3}";;
		"91 ${2} ${4} 59 55 126" ) TUISH_EVENT="ctrl-alt-${3}";;
		"91 ${2} ${4} 59 56 126" ) TUISH_EVENT="ctrl-alt-shift-${3}";;
	esac
}

# ─── Event name resolution ────────────────────────────────────────
# Overrides the stub in event.sh.  Resolves M/m (mouse), E (keyboard),
# C (character), and K (CSI u / kitty protocol) event classes into
# human-readable TUISH_EVENT names.

_tuish_resolve_event ()
{
	local _class=$1

	if test "${_class}" = 'M' || test "${_class}" = 'm'
	then
		TUISH_EVENT_KIND='mouse'
		local _mouse=''

		if test "${_class}" = 'm'
		then
			# SGR release: fire drop event if dragging, else absorb
			if test -z "$_tuish_held" && test $_tuish_detailed -eq 0
			then
				return
			fi
			local _prefix=''
			case ${2:-} in
				0     ) _mouse='ldrop';;
				1     ) _mouse='mdrop';;
				2     ) _mouse='rdrop';;
				4     ) _mouse='ldrop' _prefix='shift-';;
				5     ) _mouse='mdrop' _prefix='shift-';;
				6     ) _mouse='rdrop' _prefix='shift-';;
				8     ) _mouse='ldrop' _prefix='alt-';;
				9     ) _mouse='mdrop' _prefix='alt-';;
				10    ) _mouse='rdrop' _prefix='alt-';;
				16|96 ) _mouse='ldrop' _prefix='ctrl-';;
				17|97 ) _mouse='mdrop' _prefix='ctrl-';;
				18|98 ) _mouse='rdrop' _prefix='ctrl-';;
				24    ) _mouse='ldrop' _prefix='ctrl-alt-';;
				25    ) _mouse='mdrop' _prefix='ctrl-alt-';;
				26    ) _mouse='rdrop' _prefix='ctrl-alt-';;
				*     ) _mouse='' _prefix='';;
			esac
			_tuish_held=''
			if test -z "$_mouse"
			then
				return
			fi
			_mouse="${_prefix}${_mouse}"
		else
		case ${2:-} in
			0  ) { test -n "$_tuish_held" && _mouse="drop" && _tuish_held='' ;} || _mouse='lclik';;
			1  ) { test -n "$_tuish_held" && _mouse="drop" && _tuish_held='' ;} || _mouse='mclik';;
			2  ) { test -n "$_tuish_held" && _mouse="drop" && _tuish_held='' ;} || _mouse='rclik';;
			3  ) test -n "$_tuish_held" && _mouse="${_tuish_held}" && _tuish_held='';;
			4  ) { test -n "$_tuish_held" && _mouse="shift-drop" && _tuish_held='' ;} || _mouse='shift-lclik';;
			5  ) { test -n "$_tuish_held" && _mouse="shift-drop" && _tuish_held='' ;} || _mouse='shift-mclik';;
			6  ) { test -n "$_tuish_held" && _mouse="shift-drop" && _tuish_held='' ;} || _mouse='shift-rclik';;
			8  ) { test -n "$_tuish_held" && _mouse="alt-drop" && _tuish_held='' ;} || _mouse='alt-lclik';;
			9  ) { test -n "$_tuish_held" && _mouse="alt-drop" && _tuish_held='' ;} || _mouse='alt-mclik';;
			10 ) { test -n "$_tuish_held" && _mouse="alt-drop" && _tuish_held='' ;} || _mouse='alt-rclik';;
			16|96 ) { test -n "$_tuish_held" && _mouse="ctrl-drop" && _tuish_held='' ;} || _mouse='ctrl-lclik';;
			17|97 ) { test -n "$_tuish_held" && _mouse="ctrl-drop" && _tuish_held='' ;} || _mouse='ctrl-mclik';;
			18|98 ) { test -n "$_tuish_held" && _mouse="ctrl-drop" && _tuish_held='' ;} || _mouse='ctrl-rclik';;
			24 ) { test -n "$_tuish_held" && _mouse="ctrl-alt-drop" && _tuish_held='' ;} || _mouse='ctrl-alt-lclik';;
			25 ) { test -n "$_tuish_held" && _mouse="ctrl-alt-drop" && _tuish_held='' ;} || _mouse='ctrl-alt-mclik';;
			26 ) { test -n "$_tuish_held" && _mouse="ctrl-alt-drop" && _tuish_held='' ;} || _mouse='ctrl-alt-rclik';;
			32 ) _mouse='lhold' && _tuish_held='ldrop';;
			33 ) _mouse='mhold' && _tuish_held='mdrop';;
			34 ) _mouse='rhold' && _tuish_held='rdrop';;
			35 ) _mouse='move' && _tuish_held='';;
			36 ) _mouse='shift-lhold' && _tuish_held='ldrop';;
			37 ) _mouse='shift-mhold' && _tuish_held='mdrop';;
			38 ) _mouse='shift-rhold' && _tuish_held='rdrop';;
			39 ) _mouse='shift-move' && _tuish_held='';;
			40 ) _mouse='alt-lhold' && _tuish_held='ldrop';;
			41 ) _mouse='alt-mhold' && _tuish_held='mdrop';;
			42 ) _mouse='alt-rhold' && _tuish_held='rdrop';;
			43 ) _mouse='alt-move' && _tuish_held='';;
			48 ) _mouse='ctrl-lhold' && _tuish_held='ldrop';;
			49 ) _mouse='ctrl-mhold' && _tuish_held='mdrop';;
			50 ) _mouse='ctrl-rhold' && _tuish_held='rdrop';;
			51 ) _mouse='ctrl-move' && _tuish_held='';;
			56 ) _mouse='ctrl-alt-lhold' && _tuish_held='ldrop';;
			57 ) _mouse='ctrl-alt-mhold' && _tuish_held='mdrop';;
			58 ) _mouse='ctrl-alt-rhold' && _tuish_held='rdrop';;
			59 ) _mouse='ctrl-alt-move' && _tuish_held='';;
			64 ) _mouse='whup';;
			65 ) _mouse='wdown';;
			68 ) _mouse='shift-whup';;
			69 ) _mouse='shift-wdown';;
			72 ) _mouse='alt-whup';;
			73 ) _mouse='alt-wdown';;
			80 ) _mouse='ctrl-whup';;
			81 ) _mouse='ctrl-wdown';;
			88 ) _mouse='ctrl-alt-whup';;
			89 ) _mouse='ctrl-alt-wdown';;
			*  ) _mouse="${2:-}" && _tuish_held='';;
		esac
		fi
		TUISH_MOUSE_X=$3
		TUISH_MOUSE_Y=$4
		TUISH_MOUSE_ABS_Y=$4
		if test -n "$_tuish_view_mode"
		then
			TUISH_MOUSE_Y=$(($4 - TUISH_VIEW_TOP + 1))
		fi
		TUISH_EVENT="$_mouse"

	elif test "$_class" = 'E'
	then
		TUISH_EVENT_KIND='key'
		shift
		TUISH_EVENT=''

		# Extract event type sub-parameter (:1=press :2=repeat :3=release)
		local _e_seq="${*:-27}"
		local _e_suffix=''
		case "$_e_seq" in
			*' 58 50 '*) _e_suffix='-rep'; _e_seq="${_e_seq%% 58 50 *} ${_e_seq##* 58 50 }";;
			*' 58 50')   _e_suffix='-rep'; _e_seq="${_e_seq% 58 50}";;
			*' 58 51 '*) _e_suffix='-rel'; _e_seq="${_e_seq%% 58 51 *} ${_e_seq##* 58 51 }";;
			*' 58 51')   _e_suffix='-rel'; _e_seq="${_e_seq% 58 51}";;
			*' 58 49 '*) _e_seq="${_e_seq%% 58 49 *} ${_e_seq##* 58 49 }";;
			*' 58 49')   _e_seq="${_e_seq% 58 49}";;
		esac

		case "$_e_seq" in
			'8'   ) TUISH_EVENT='ctrl-bksp';;
			'9'   ) TUISH_EVENT='tab';;
			'10'|'13' ) TUISH_EVENT='enter';;
			'27'  ) TUISH_EVENT='esc';;
			'28'  ) TUISH_EVENT='ctrl-bslash';;
			'29'  ) TUISH_EVENT='ctrl-]';;
			'30'  ) TUISH_EVENT='ctrl-^';;
			'31'  ) TUISH_EVENT='ctrl-_';;
			'127' ) TUISH_EVENT='bksp';;

			'27 8'  ) TUISH_EVENT='alt-bksp';;
			'27 9'  ) TUISH_EVENT='alt-tab';;
			'27 10'|'27 13' ) TUISH_EVENT='alt-enter';;
			'27 127') TUISH_EVENT='alt-bksp';;

			'91 90' ) TUISH_EVENT='shift-tab';;
			'91 73' ) TUISH_EVENT='focus-in';;
			'91 79' ) TUISH_EVENT='focus-out';;
			'91 50 48 48 126' ) TUISH_EVENT='paste-start';;
			'91 50 48 49 126' ) TUISH_EVENT='paste-end';;

			'79 65' | '91 65' ) TUISH_EVENT='up';;
			'79 66' | '91 66' ) TUISH_EVENT='down';;
			'79 67' | '91 67' ) TUISH_EVENT='right';;
			'79 68' | '91 68' ) TUISH_EVENT='left';;

			'79 80' | '91 80' ) TUISH_EVENT='f1';;
			'79 81' | '91 81' ) TUISH_EVENT='f2';;
			'79 82' | '91 82' ) TUISH_EVENT='f3';;
			'79 83' | '91 83' ) TUISH_EVENT='f4';;
			'91 49 53 126' ) TUISH_EVENT='f5' ;;
			'91 49 55 126' ) TUISH_EVENT='f6' ;;
			'91 49 56 126' ) TUISH_EVENT='f7' ;;
			'91 49 57 126' ) TUISH_EVENT='f8' ;;
			'91 50 48 126' ) TUISH_EVENT='f9' ;;
			'91 50 49 126' ) TUISH_EVENT='f10' ;;
			'91 50 51 126' ) TUISH_EVENT='f11' ;;
			'91 50 52 126' ) TUISH_EVENT='f12' ;;

			'79 72' | '91 72' | '91 49 126' ) TUISH_EVENT='home';;
			'79 70' | '91 70' | '91 52 126' ) TUISH_EVENT='end';;
			'91 50 126' ) TUISH_EVENT='ins';;
			'91 51 126' ) TUISH_EVENT='del';;
			'91 53 126' ) TUISH_EVENT='pgup';;
			'91 54 126' ) TUISH_EVENT='pgdn';;
		esac

		if test -z "$TUISH_EVENT"
		then
		_tuish_5code_modifiers "$_e_seq" '49' 'up' '65'
		_tuish_5code_modifiers "$_e_seq" '49' 'down' '66'
		_tuish_5code_modifiers "$_e_seq" '49' 'right' '67'
		_tuish_5code_modifiers "$_e_seq" '49' 'left' '68'

		_tuish_5code_modifiers "$_e_seq" '49' 'f1' '80'
		_tuish_5code_modifiers "$_e_seq" '49' 'f2' '81'
		_tuish_5code_modifiers "$_e_seq" '49' 'f3' '82'
		_tuish_5code_modifiers "$_e_seq" '49' 'f4' '83'

		_tuish_6code_modifiers "$_e_seq" '49' 'f5' '53'
		_tuish_6code_modifiers "$_e_seq" '49' 'f6' '55'
		_tuish_6code_modifiers "$_e_seq" '49' 'f7' '56'
		_tuish_6code_modifiers "$_e_seq" '49' 'f8' '57'
		_tuish_6code_modifiers "$_e_seq" '50' 'f9' '48'
		_tuish_6code_modifiers "$_e_seq" '50' 'f10' '49'
		_tuish_6code_modifiers "$_e_seq" '50' 'f11' '51'
		_tuish_6code_modifiers "$_e_seq" '50' 'f12' '52'

		_tuish_5code_modifiers "$_e_seq" '49' 'home' '72'
		_tuish_5code_modifiers "$_e_seq" '49' 'end' '70'
		_tuish_5code_modifiers "$_e_seq" '50' 'ins' '126'
		_tuish_5code_modifiers "$_e_seq" '51' 'del' '126'
		_tuish_5code_modifiers "$_e_seq" '53' 'pgup' '126'
		_tuish_5code_modifiers "$_e_seq" '54' 'pgdn' '126'
		fi

		if test -z "${TUISH_EVENT}"
		then
			if test "$TUISH_PROTOCOL" = 'kitty'
			then
				# _tuish_kitty_raw: 'func' = raw bytes are functional
				# keys, 'letter' = raw bytes are ctrl+letter (some
				# terminals leak raw ctrl bytes despite kitty mode)
				if test "$#" -eq 1
				then
					if test $1 -ge 32 && test $1 -le 126
					then
						eval "TUISH_EVENT=\"alt-\$_tuish_chr_$1\""
					elif test $1 -ge 1 && test $1 -le 26
					then
						case $1 in
							8)
								TUISH_EVENT='ctrl-bksp';;
							9) TUISH_EVENT='tab';;
							10|13) TUISH_EVENT='enter';;
							*)
								if test "$_tuish_kitty_raw" = 'letter'
								then
									eval "TUISH_EVENT=\"ctrl-\$_tuish_chr_$(($1 + 96))\""
								else
									# Full CSI u: raw bytes are functional keys
									case $1 in
										23) TUISH_EVENT='ctrl-bksp';;
										*)  eval "TUISH_EVENT=\"ctrl-\$_tuish_chr_$(($1 + 96))\"";;
									esac
								fi
								;;
						esac
					else
						TUISH_EVENT="MISS ${*:-27}"
					fi
				elif test "$#" -eq 2 && test "$1" -eq 27
				then
					if test "$2" -ge 32 && test "$2" -le 126
					then
						case $2 in
							100) TUISH_EVENT='ctrl-del';;
							*) eval "TUISH_EVENT=\"alt-\$_tuish_chr_$2\"";;
						esac
					elif test "$2" -ge 1 && test "$2" -le 26
					then
						eval "TUISH_EVENT=\"ctrl-alt-\$_tuish_chr_$(($2 + 96))\""
					else
						TUISH_EVENT="MISS ${*:-27}"
					fi
				else
					TUISH_EVENT="MISS ${*:-27}"
				fi
			else
				if test "$#" -eq 1
				then
					if test $1 -ge 32 && test $1 -le 126
					then
						eval "TUISH_EVENT=\"alt-\$_tuish_chr_$1\""
					elif test $1 -ge 1 && test $1 -le 26
					then
						eval "TUISH_EVENT=\"ctrl-\$_tuish_chr_$(($1 + 96))\""
					else
						TUISH_EVENT="MISS ${*:-27}"
					fi
				elif test "$#" -eq 2 && test "$1" -eq 27
				then
					if test "$2" -ge 32 && test "$2" -le 126
					then
						eval "TUISH_EVENT=\"alt-\$_tuish_chr_$2\""
					elif test "$2" -ge 1 && test "$2" -le 26
					then
						eval "TUISH_EVENT=\"ctrl-alt-\$_tuish_chr_$(($2 + 96))\""
					else
						TUISH_EVENT="MISS ${*:-27}"
					fi
				else
					TUISH_EVENT="MISS ${*:-27}"
				fi
			fi
		fi

		# Apply event type suffix
		test -n "$_e_suffix" && test -n "$TUISH_EVENT" && TUISH_EVENT="${TUISH_EVENT}${_e_suffix}"

		# Override kind for non-keyboard escape sequences
		case "$TUISH_EVENT" in
			focus-*) TUISH_EVENT_KIND='focus';;
			paste-*) TUISH_EVENT_KIND='paste';;
		esac

	elif test "$_class" = 'C'
	then
		TUISH_EVENT_KIND='key'
		if test "${2:-}" != '\'
		then
			TUISH_EVENT="${2:+char }${2:-space}"
		else
			TUISH_EVENT="char bslash"
		fi

	elif test "$_class" = 'K'
	then
		TUISH_EVENT_KIND='key'
		# CSI u (kitty keyboard protocol)
		local _ku_keycode="${2%%[;:]*}"
		local _ku_mod=1
		local _ku_type=1
		local _ku_rest="${2#"$_ku_keycode"}"
		if test -n "$_ku_rest"
		then
			_ku_rest="${_ku_rest#;}"
			_ku_mod="${_ku_rest%%[:]*}"
			local _ku_t="${_ku_rest#"$_ku_mod"}"
			test "${_ku_t}" != "${_ku_t#:}" && _ku_type="${_ku_t#:}"
		fi

		local _ku_bits=$((_ku_mod - 1))

		# For modifier keycodes, clear the self-referential modifier bit
		case "$_ku_keycode" in
			57441|57447) _ku_bits=$((_ku_bits & ~1));;
			57443|57449) _ku_bits=$((_ku_bits & ~2));;
			57442|57448) _ku_bits=$((_ku_bits & ~4));;
			57444|57450) _ku_bits=$((_ku_bits & ~8));;
			57445|57451) _ku_bits=$((_ku_bits & ~16));;
			57446|57452) _ku_bits=$((_ku_bits & ~32));;
		esac

		local _ku_prefix=''
		test $((_ku_bits & 4)) -ne 0 && _ku_prefix="${_ku_prefix}ctrl-"
		test $((_ku_bits & 2)) -ne 0 && _ku_prefix="${_ku_prefix}alt-"
		test $((_ku_bits & 1)) -ne 0 && _ku_prefix="${_ku_prefix}shift-"
		test $((_ku_bits & 8)) -ne 0 && _ku_prefix="${_ku_prefix}super-"
		test $((_ku_bits & 16)) -ne 0 && _ku_prefix="${_ku_prefix}hyper-"
		test $((_ku_bits & 32)) -ne 0 && _ku_prefix="${_ku_prefix}meta-"

		local _ku_key=''
		case "$_ku_keycode" in
			9) _ku_key='tab';;
			13) _ku_key='enter';;
			27) _ku_key='esc';;
			32) _ku_key='space';;
			92) _ku_key='bslash';;
			127) _ku_key='bksp';;
			57358) _ku_key='caps-lock';;
			57359) _ku_key='scroll-lock';;
			57360) _ku_key='num-lock';;
			57361) _ku_key='prtsc';;
			57362) _ku_key='pause';;
			57363) _ku_key='menu';;
			57409) _ku_key='kp-.';;
			57410) _ku_key='kp-/';;
			57411) _ku_key='kp-*';;
			57412) _ku_key='kp--';;
			57413) _ku_key='kp-+';;
			57414) _ku_key='kp-enter';;
			57415) _ku_key='kp-=';;
			57416) _ku_key='kp-sep';;
			57417) _ku_key='kp-left';;
			57418) _ku_key='kp-right';;
			57419) _ku_key='kp-up';;
			57420) _ku_key='kp-down';;
			57421) _ku_key='kp-pgup';;
			57422) _ku_key='kp-pgdn';;
			57423) _ku_key='kp-home';;
			57424) _ku_key='kp-end';;
			57425) _ku_key='kp-ins';;
			57426) _ku_key='kp-del';;
			57427) _ku_key='kp-begin';;
			57428) _ku_key='media-play';;
			57429) _ku_key='media-pause';;
			57430) _ku_key='media-play-pause';;
			57431) _ku_key='media-reverse';;
			57432) _ku_key='media-stop';;
			57433) _ku_key='media-ff';;
			57434) _ku_key='media-rw';;
			57435) _ku_key='media-next';;
			57436) _ku_key='media-prev';;
			57437) _ku_key='media-rec';;
			57438) _ku_key='vol-down';;
			57439) _ku_key='vol-up';;
			57440) _ku_key='vol-mute';;
			57441) _ku_key='shift.l';;
			57442) _ku_key='ctrl.l';;
			57443) _ku_key='alt.l';;
			57444) _ku_key='super.l';;
			57445) _ku_key='hyper.l';;
			57446) _ku_key='meta.l';;
			57447) _ku_key='shift.r';;
			57448) _ku_key='ctrl.r';;
			57449) _ku_key='alt.r';;
			57450) _ku_key='super.r';;
			57451) _ku_key='hyper.r';;
			57452) _ku_key='meta.r';;
			57453) _ku_key='iso-level3';;
			57454) _ku_key='iso-level5';;
			*)
				if test "$_ku_keycode" -ge 57376 2>/dev/null && test "$_ku_keycode" -le 57398
				then
					_ku_key="f$((_ku_keycode - 57363))"
				elif test "$_ku_keycode" -ge 57399 2>/dev/null && test "$_ku_keycode" -le 57408
				then
					_ku_key="kp-$((_ku_keycode - 57399))"
				elif test "$_ku_keycode" -ge 57348 2>/dev/null && test "$_ku_keycode" -le 57357
				then
					case "$((_ku_keycode - 57348))" in
						0) _ku_key='ins';; 1) _ku_key='del';;
						2) _ku_key='left';; 3) _ku_key='right';;
						4) _ku_key='up';; 5) _ku_key='down';;
						6) _ku_key='pgup';; 7) _ku_key='pgdn';;
						8) _ku_key='home';; 9) _ku_key='end';;
					esac
				elif test "$_ku_keycode" -ge 33 2>/dev/null && test "$_ku_keycode" -le 126
				then
					eval "_ku_key=\"\$_tuish_chr_$_ku_keycode\""
				else
					_ku_key="key-${_ku_keycode}"
				fi
				;;
		esac

		# ctrl+letter via CSI u → terminal has full flag 8 support
		if test "$_tuish_kitty_raw" = 'letter' &&
		   test $((_ku_bits & 4)) -ne 0 &&
		   test "$_ku_keycode" -ge 97 2>/dev/null && test "$_ku_keycode" -le 122
		then
			_tuish_kitty_raw='func'
		fi

		local _ku_suffix=''
		case "$_ku_type" in
			2) _ku_suffix='-rep';;
			3) _ku_suffix='-rel';;
		esac

		# Unmodified printable press: match C handler format
		if test -z "$_ku_prefix" && test -z "$_ku_suffix" &&
		   test "$_ku_keycode" -ge 33 2>/dev/null && test "$_ku_keycode" -le 126
		then
			TUISH_EVENT="char ${_ku_key}"
		else
			TUISH_EVENT="${_ku_prefix}${_ku_key}${_ku_suffix}"
		fi
	fi
}
