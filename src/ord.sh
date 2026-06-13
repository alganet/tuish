# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/ord.sh - ASCII ord/chr lookup tables
# Source after compat.sh.  Do not execute directly.
#
# Provides:
#   _tuish_ord()    - character → ASCII code (result in _tuish_code)
#   _tuish_chr_N    - code → character lookup variables (_tuish_chr_1 .. _tuish_chr_127)
#
# Dependencies: compat.sh (_tuish_printf, _tuish_out(), alias local=typeset)

# ─── ASCII lookup tables ─────────────────────────────────────────
# Precomputed chr (code→char) and ord (char→code) tables for codes 1-255.
# Avoids repeated subshell forks in event parsing and string width.
# Bytes 128-255 (UTF-8 lead/continuation) feed the fork-free _tuish_ord_hi
# fallback below; byte 0 is never stored (can't live in a shell variable).

_tuish_init_tables ()
{
	local _i=1 _chr='' _d1 _d2 _d3
	if printf -v _chr 'x' >/dev/null 2>&1 && test "$_chr" = 'x'
	then
		# bash/zsh: printf -v avoids all subshells
		while test $_i -le 255
		do
			_d1=$((_i / 64)); _d2=$(( (_i / 8) % 8 )); _d3=$((_i % 8))
			printf -v _chr "\\${_d1}${_d2}${_d3}"
			eval "_tuish_chr_$_i=\"\$_chr\""
			_i=$((_i + 1))
		done
	elif test $_tuish_printf -eq 0
	then
		# mksh: builtin echo -ne with \0NNN octal (no external printf)
		while test $_i -le 255
		do
			_d1=$((_i / 64)); _d2=$(( (_i / 8) % 8 )); _d3=$((_i % 8))
			_chr=$(echo -ne "\\0${_d1}${_d2}${_d3}")
			eval "_tuish_chr_$_i=\"\$_chr\""
			_i=$((_i + 1))
		done
	else
		# ksh93/busybox: one subshell per char (down from two)
		while test $_i -le 255
		do
			_d1=$((_i / 64)); _d2=$(( (_i / 8) % 8 )); _d3=$((_i % 8))
			_chr=$(printf "\\${_d1}${_d2}${_d3}")
			eval "_tuish_chr_$_i=\"\$_chr\""
			_i=$((_i + 1))
		done
	fi
}
_tuish_init_tables

# ─── Fork-free high/non-printable byte lookup ────────────────────
# _tuish_ord's literal case (below) covers fast printable ASCII (0x20-0x7E).
# Every other byte — UTF-8 lead/continuation (0x80-0xFF) and control bytes
# — used to fall through to a `$(printf '%d' ...)` SUBSHELL FORK, paid once
# per non-ASCII byte (catastrophic for CJK/emoji width and UTF-8 input).
#
# Build a fork-free fallback once at init: a generated case keyed on the chr
# table. The generated source contains only the literal text
# "$_tuish_chr_NNN") — the value is substituted at match time, inside double
# quotes, where backslash/glob metacharacters match literally. So no byte
# ever appears raw in the eval'd source: zero escaping hazards.
#
# High bytes (128-255) are emitted first since they are the common path; the
# returned value is the true UNSIGNED 1-255 (the old fork could yield a
# negative on signed-char platforms — this is strictly more correct).
_tuish_build_ord_hi ()
{
	local _i _body=''
	_i=128
	while test $_i -le 255
	do
		_body="${_body}\"\$_tuish_chr_${_i}\") _tuish_code=${_i};; "
		_i=$((_i + 1))
	done
	_i=1
	while test $_i -le 127
	do
		_body="${_body}\"\$_tuish_chr_${_i}\") _tuish_code=${_i};; "
		_i=$((_i + 1))
	done
	eval "_tuish_ord_hi () { case \"\$1\" in ${_body}*) _tuish_code=0;; esac; }"
}

# bash/zsh have `printf -v` (a fork-free assignment) and can resolve any byte
# in O(1): `printf '%d' "'<byte>"` yields the char's value, signed on
# signed-char platforms, so correct back to unsigned 1-255. Shells without
# `printf -v` (ksh93/mksh/busybox) use the generated linear-scan case, which
# is still fork-free. Same capability probe as _tuish_init_tables.
if printf -v _tuish_pv_probe '%d' "'x" >/dev/null 2>&1 && test "${_tuish_pv_probe:-}" = '120'
then
	_tuish_ord_hi ()
	{
		printf -v _tuish_code '%d' "'$1"
		# Explicit `if` (not `test && assign`): the latter returns non-zero
		# when the byte is already positive, which trips `set -euf` callers.
		if test "$_tuish_code" -lt 0
		then
			_tuish_code=$((_tuish_code + 256))
		fi
	}
	unset _tuish_pv_probe 2>/dev/null || _tuish_pv_probe=''
else
	_tuish_build_ord_hi
fi

# Fast ord: literal case for printable ASCII (no var expansion — hot input
# path), fork-free _tuish_ord_hi for every other byte (UTF-8 + control).
_tuish_ord ()
{
	case "$1" in
		' ') _tuish_code=32;; '!') _tuish_code=33;;
		'"') _tuish_code=34;; '#') _tuish_code=35;;
		'$') _tuish_code=36;; '%') _tuish_code=37;;
		'&') _tuish_code=38;; "'") _tuish_code=39;;
		'(') _tuish_code=40;; ')') _tuish_code=41;;
		'*') _tuish_code=42;; '+') _tuish_code=43;;
		',') _tuish_code=44;; '-') _tuish_code=45;;
		'.') _tuish_code=46;; '/') _tuish_code=47;;
		0) _tuish_code=48;; 1) _tuish_code=49;;
		2) _tuish_code=50;; 3) _tuish_code=51;;
		4) _tuish_code=52;; 5) _tuish_code=53;;
		6) _tuish_code=54;; 7) _tuish_code=55;;
		8) _tuish_code=56;; 9) _tuish_code=57;;
		':') _tuish_code=58;; ';') _tuish_code=59;;
		'<') _tuish_code=60;; '=') _tuish_code=61;;
		'>') _tuish_code=62;; '?') _tuish_code=63;;
		'@') _tuish_code=64;;
		A) _tuish_code=65;; B) _tuish_code=66;;
		C) _tuish_code=67;; D) _tuish_code=68;;
		E) _tuish_code=69;; F) _tuish_code=70;;
		G) _tuish_code=71;; H) _tuish_code=72;;
		I) _tuish_code=73;; J) _tuish_code=74;;
		K) _tuish_code=75;; L) _tuish_code=76;;
		M) _tuish_code=77;; N) _tuish_code=78;;
		O) _tuish_code=79;; P) _tuish_code=80;;
		Q) _tuish_code=81;; R) _tuish_code=82;;
		S) _tuish_code=83;; T) _tuish_code=84;;
		U) _tuish_code=85;; V) _tuish_code=86;;
		W) _tuish_code=87;; X) _tuish_code=88;;
		Y) _tuish_code=89;; Z) _tuish_code=90;;
		'[') _tuish_code=91;; \\) _tuish_code=92;;
		']') _tuish_code=93;; '^') _tuish_code=94;;
		_) _tuish_code=95;; '`') _tuish_code=96;;
		a) _tuish_code=97;; b) _tuish_code=98;;
		c) _tuish_code=99;; d) _tuish_code=100;;
		e) _tuish_code=101;; f) _tuish_code=102;;
		g) _tuish_code=103;; h) _tuish_code=104;;
		i) _tuish_code=105;; j) _tuish_code=106;;
		k) _tuish_code=107;; l) _tuish_code=108;;
		m) _tuish_code=109;; n) _tuish_code=110;;
		o) _tuish_code=111;; p) _tuish_code=112;;
		q) _tuish_code=113;; r) _tuish_code=114;;
		s) _tuish_code=115;; t) _tuish_code=116;;
		u) _tuish_code=117;; v) _tuish_code=118;;
		w) _tuish_code=119;; x) _tuish_code=120;;
		y) _tuish_code=121;; z) _tuish_code=122;;
		'{') _tuish_code=123;; '|') _tuish_code=124;;
		'}') _tuish_code=125;; '~') _tuish_code=126;;
		*) _tuish_ord_hi "$1";;
	esac
}
