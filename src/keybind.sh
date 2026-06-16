# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Load guard: skip re-definition if already sourced (see tui.sh).
if test -n "${_tuish_keybind_loaded:-}"; then return 0; fi
_tuish_keybind_loaded=1
# src/keybind.sh - Declarative key binding dispatch
# Optional module. Source after ord.sh.
#
# Provides:
#   tuish_bind EVENT ACTION   - bind event to shell function/command
#   tuish_unbind EVENT        - remove binding
#   tuish_dispatch            - dispatch TUISH_EVENT through bindings
#
# Bindings are stored as variables: _tuish_kb_<sanitized_event>=action.
# The event name is sanitized injectively: alphanumerics and the escape
# underscores survive; every other byte (including a literal '_') becomes
# _<decimal-ord>_, so two distinct events can never collide on one key.
#
# Dependencies: _tuish_ord() (from src/ord.sh)

_tuish_kb_sanitize ()
{
	# Event name -> injective variable suffix in _tuish_kb_key. Escaping the
	# literal '_' first lets the common specials map to their own _<ord>_ form
	# via fast ${//} (no per-char loop on the dispatch hot path); only rarely
	# typed bytes fall through to the char-by-char encoder.
	_tuish_kb_key="$1"
	_tuish_kb_key="${_tuish_kb_key//_/_95_}"
	_tuish_kb_key="${_tuish_kb_key//-/_45_}"
	_tuish_kb_key="${_tuish_kb_key//./_46_}"
	_tuish_kb_key="${_tuish_kb_key// /_32_}"
	_tuish_kb_key="${_tuish_kb_key//\*/_42_}"
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

# Catch-all key, resolved once (sanitize is pure for a fixed input).
_tuish_kb_sanitize '*'
_tuish_kb_star="$_tuish_kb_key"

tuish_bind ()
{
	_tuish_kb_sanitize "$1"
	eval "_tuish_kb_${_tuish_kb_key}=\"\$2\""
}

tuish_unbind ()
{
	_tuish_kb_sanitize "$1"
	eval "unset _tuish_kb_${_tuish_kb_key}"
}

tuish_dispatch ()
{
	# Exact match
	_tuish_kb_sanitize "$TUISH_EVENT"
	eval "local _d_action=\"\${_tuish_kb_${_tuish_kb_key}:-}\""
	if test -n "$_d_action"; then eval "$_d_action"; return 0; fi

	# Glob prefix: a "char *" binding matches any "char X"
	local _d_prefix="${TUISH_EVENT%% *}"
	if test "$_d_prefix" != "$TUISH_EVENT"
	then
		_tuish_kb_sanitize "${_d_prefix} *"
		eval "_d_action=\"\${_tuish_kb_${_tuish_kb_key}:-}\""
		if test -n "$_d_action"; then eval "$_d_action"; return 0; fi
	fi

	# Wildcard catch-all "*"
	eval "_d_action=\"\${_tuish_kb_${_tuish_kb_star}:-}\""
	if test -n "$_d_action"; then eval "$_d_action"; return 0; fi

	return 1
}
