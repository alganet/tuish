# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/keybind.sh - Declarative key binding dispatch
# Optional module. Source after ord.sh.
#
# Provides:
#   tuish_bind EVENT ACTION   - bind event to shell function/command
#   tuish_unbind EVENT        - remove binding
#   tuish_dispatch            - dispatch TUISH_EVENT through bindings
#
# Bindings are stored as variables: _tuish_kb_<sanitized_event>=action
# Events with special chars are sanitized: - → _D  . → _P  * → _S  space → _W
#
# Dependencies: _tuish_ord() (from src/ord.sh)

_tuish_kb_count=0

_tuish_kb_sanitize ()
{
	# Event name → valid variable suffix (_tuish_kb_key)
	_tuish_kb_key="$1"
	_tuish_kb_key="${_tuish_kb_key//-/_D}"
	_tuish_kb_key="${_tuish_kb_key//./_P}"
	_tuish_kb_key="${_tuish_kb_key//\*/_S}"
	_tuish_kb_key="${_tuish_kb_key// /_W}"
	# If non-variable-safe chars remain (e.g. typed ' ; ( etc.), encode them
	case "$_tuish_kb_key" in *[!A-Za-z0-9_]*)
		local _kb_tmp="$_tuish_kb_key" _kb_out='' _kb_i=0 _kb_c
		while test $_kb_i -lt ${#_kb_tmp}
		do
			_kb_c="${_kb_tmp:$_kb_i:1}"
			case "$_kb_c" in
				[A-Za-z0-9_]) _kb_out="${_kb_out}${_kb_c}";;
				*) _tuish_ord "$_kb_c"; _kb_out="${_kb_out}_${_tuish_code}_";;
			esac
			_kb_i=$((_kb_i + 1))
		done
		_tuish_kb_key="$_kb_out";;
	esac
}

tuish_bind ()
{
	_tuish_kb_sanitize "$1"
	eval "_tuish_kb_${_tuish_kb_key}=\"\$2\""
	# Track event name for iteration
	_tuish_kb_count=$((_tuish_kb_count + 1))
	eval "_tuish_kb_ev_${_tuish_kb_count}=\"\$1\""
}

tuish_unbind ()
{
	_tuish_kb_sanitize "$1"
	eval "unset _tuish_kb_${_tuish_kb_key}"
	# Remove from event list
	local _ub_i=1
	while test $_ub_i -le $_tuish_kb_count
	do
		eval "local _ub_ev=\"\${_tuish_kb_ev_${_ub_i}:-}\""
		if test "$_ub_ev" = "$1"
		then
			eval "unset _tuish_kb_ev_${_ub_i}"
			break
		fi
		_ub_i=$((_ub_i + 1))
	done
}

tuish_dispatch ()
{
	# Try exact match first
	_tuish_kb_sanitize "$TUISH_EVENT"
	eval "local _d_action=\"\${_tuish_kb_${_tuish_kb_key}:-}\""
	if test -n "$_d_action"
	then
		eval "$_d_action"
		return 0
	fi

	# Try glob-style prefix match: "char *" matches any "char X"
	# Check "char *" for events like "char a", "char b", etc.
	local _d_prefix="${TUISH_EVENT%% *}"
	if test "$_d_prefix" != "$TUISH_EVENT"
	then
		_tuish_kb_sanitize "${_d_prefix} *"
		eval "_d_action=\"\${_tuish_kb_${_tuish_kb_key}:-}\""
		if test -n "$_d_action"
		then
			eval "$_d_action"
			return 0
		fi
	fi

	# Try wildcard catch-all (sanitize("*") = "_S", hardcoded)
	eval "_d_action=\"\${_tuish_kb__S:-}\""
	if test -n "$_d_action"
	then
		eval "$_d_action"
		return 0
	fi

	return 1
}
