# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/buf.sh - Line buffer with index-based operations
# Optional module. Source after compat.sh.
#
# Provides:
#   TUISH_BUF_COUNT              - number of lines (default or last queried buffer)
#   tuish_buf_init [PREFIX]      - initialize buffer (one empty line)
#   tuish_buf_count [PREFIX]     - load named buffer's count into TUISH_BUF_COUNT
#   tuish_buf_get [PREFIX] IDX   - get line at index (1-based) -> TUISH_BLINE
#   tuish_buf_set [PREFIX] IDX VAL - set line at index
#   tuish_buf_append [PREFIX] VAL  - append line to end
#   tuish_buf_insert_at [PREFIX] IDX VAL - insert line at index, shift others down
#   tuish_buf_delete_at [PREFIX] IDX     - delete line at index, shift others up
#
# Without PREFIX, operates on the default (global) buffer.
# With PREFIX, operates on an independent named buffer.
#
# Dependencies: none

TUISH_BUF_COUNT=0

tuish_buf_count ()
{
	if test $# -gt 0
	then eval "TUISH_BUF_COUNT=\$_tuish_bufcount_$1"
	fi
}

tuish_buf_get ()
{
	if test $# -gt 1
	then eval "_tuish_bline=\"\$_tuish_buf_${1}_$2\""
	else eval "_tuish_bline=\"\$_tuish_buf_$1\""
	fi
	TUISH_BLINE=$_tuish_bline
}

tuish_buf_set ()
{
	if test $# -gt 2
	then eval "_tuish_buf_${1}_$2=\"\$3\""
	else eval "_tuish_buf_$1=\"\$2\""
	fi
}

tuish_buf_init ()
{
	if test $# -gt 0; then
		eval "_tuish_bufcount_$1=0"
		tuish_buf_append "$1" ''
	else
		TUISH_BUF_COUNT=0
		tuish_buf_append ''
	fi
}

tuish_buf_append ()
{
	local _c
	if test $# -gt 1; then
		eval "_c=\$_tuish_bufcount_$1"
		_c=$((_c + 1))
		eval "_tuish_bufcount_$1=$_c"
		eval "_tuish_buf_${1}_$_c=\"\$2\""
	else
		TUISH_BUF_COUNT=$((TUISH_BUF_COUNT + 1))
		eval "_tuish_buf_$TUISH_BUF_COUNT=\"\$1\""
	fi
}

tuish_buf_insert_at ()
{
	local _idx _val _p _c _i
	if test $# -gt 2; then
		_p="${1}_"; _idx=$2; _val="$3"
		eval "_c=\$_tuish_bufcount_$1"
		_i=$_c
		_c=$((_c + 1))
		eval "_tuish_bufcount_$1=$_c"
	else
		_p=''; _idx=$1; _val="$2"
		_i=$TUISH_BUF_COUNT
		TUISH_BUF_COUNT=$((TUISH_BUF_COUNT + 1))
	fi
	while test $_i -ge $_idx; do
		eval "_tuish_buf_${_p}$((_i + 1))=\"\$_tuish_buf_${_p}$_i\""
		_i=$((_i - 1))
	done
	eval "_tuish_buf_${_p}${_idx}=\"\$_val\""
}

tuish_buf_delete_at ()
{
	local _idx _p _c _i
	if test $# -gt 1; then
		_p="${1}_"; _idx=$2
		eval "_c=\$_tuish_bufcount_$1"
	else
		_p=''; _idx=$1
		_c=$TUISH_BUF_COUNT
	fi
	_i=$_idx
	while test $_i -lt $_c; do
		eval "_tuish_buf_${_p}$_i=\"\$_tuish_buf_${_p}$((_i + 1))\""
		_i=$((_i + 1))
	done
	_c=$((_c - 1))
	if test $# -gt 1
	then eval "_tuish_bufcount_$1=$_c"
	else TUISH_BUF_COUNT=$_c
	fi
}
