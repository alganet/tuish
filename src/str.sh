# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/str.sh - String utilities and Unicode width
# Optional module. Source after tui.sh.
#
# Provides:
#   tuish_str_len/left/right/char - character-level string ops (byte-mode UTF-8)
#   tuish_str_width              - display width (columns)
#   tuish_str_repeat             - O(log n) string repetition
#   _tuish_char_width()          - codepoint → display width
#   _tuish_byte_val/utf8_len/utf8_decode/char_byte_off - UTF-8 internals
#
# Dependencies: _tuish_ord() (from src/ord.sh)
#
# Requires LC_ALL=C (set by compat.sh) for byte-oriented string indexing.

# ─── String utilities (byte-mode UTF-8 decoding) ─────────────────
# All take a variable NAME to avoid subshell overhead.
# Results in TUISH_SLEN, TUISH_SLEFT, TUISH_SRIGHT, TUISH_SCHAR.
# Legacy aliases: _tuish_slen, _tuish_sleft, _tuish_sright, _tuish_schar.

tuish_str_len ()
{
	eval "local _sl_str=\"\${$1}\""
	# Fast path: printable ASCII → byte count = char count
	case "$_sl_str" in *[![:print:]]*)
		local _sl_i=0
		_tuish_slen=0
		while _tuish_byte_val "$1" $_sl_i
		do
			_tuish_utf8_len $_tuish_bval
			_sl_i=$((_sl_i + _tuish_cbytes))
			_tuish_slen=$((_tuish_slen + 1))
		done
		TUISH_SLEN=$_tuish_slen
		return;;
	esac
	_tuish_slen=${#_sl_str}
	TUISH_SLEN=$_tuish_slen
}

tuish_str_left ()
{
	# Fast path: if first $2 bytes are printable ASCII, byte off = char off
	eval "_tuish_sleft=\"\${$1:0:$2}\""
	case "$_tuish_sleft" in *[![:print:]]*)
		_tuish_char_byte_off "$1" "$2"
		eval "_tuish_sleft=\"\${$1:0:$_tuish_boff}\"";;
	esac
	TUISH_SLEFT=$_tuish_sleft
}

tuish_str_right ()
{
	# Fast path: if first $2 bytes are printable ASCII, byte off = char off
	eval "local _sr_pre=\"\${$1:0:$2}\""
	case "$_sr_pre" in *[![:print:]]*)
		_tuish_char_byte_off "$1" "$2"
		eval "_tuish_sright=\"\${$1:$_tuish_boff}\""
		TUISH_SRIGHT=$_tuish_sright
		return;;
	esac
	eval "_tuish_sright=\"\${$1:$2}\""
	TUISH_SRIGHT=$_tuish_sright
}

tuish_str_char ()
{
	# Fast path: if first $2+1 bytes are printable ASCII, byte off = char off
	eval "local _sc_pre=\"\${$1:0:$(($2 + 1))}\""
	case "$_sc_pre" in *[![:print:]]*)
		_tuish_char_byte_off "$1" "$2"
		_tuish_byte_val "$1" $_tuish_boff || { _tuish_schar=''; TUISH_SCHAR=''; return; }
		_tuish_utf8_len $_tuish_bval
		eval "_tuish_schar=\"\${$1:$_tuish_boff:$_tuish_cbytes}\""
		TUISH_SCHAR=$_tuish_schar
		return;;
	esac
	eval "_tuish_schar=\"\${$1:$2:1}\""
	TUISH_SCHAR=$_tuish_schar
}

# Repeat string $1 exactly $2 times. O(log n) via doubling.
# Result in TUISH_SREPEATED (legacy: _tuish_srepeated).
_tuish_str_repeat ()
{
	local _sr_s="$1" _sr_n=$2
	_tuish_srepeated=''
	while test $_sr_n -gt 0
	do
		test $((_sr_n & 1)) -ne 0 && _tuish_srepeated="${_tuish_srepeated}${_sr_s}"
		_sr_s="${_sr_s}${_sr_s}"
		_sr_n=$((_sr_n >> 1))
	done
	TUISH_SREPEATED=$_tuish_srepeated
}
tuish_str_repeat () { _tuish_str_repeat "$@"; }

# ─── Text width (display columns) ────────────────────────────────
# UTF-8 decode → codepoint → width classification.
# Result in TUISH_SWIDTH. Takes a variable NAME.

tuish_str_width ()
{
	eval "local _sw_str=\"\${$1}\""
	local _sw_len=${#_sw_str}
	# Fast path: under LC_ALL=C, [:print:] is exactly 0x20-0x7E.
	# All printable ASCII chars have width 1, so width = byte count.
	case "$_sw_str" in *[![:print:]]*) ;; *) _tuish_swidth=$_sw_len; TUISH_SWIDTH=$_sw_len; return;; esac
	local _sw_i=0
	_tuish_swidth=0
	while _tuish_utf8_decode "$1" $_sw_i
	do
		_sw_i=$((_sw_i + _tuish_cbytes))
		_tuish_char_width $_tuish_code
		_tuish_swidth=$((_tuish_swidth + _tuish_cw))
	done
	TUISH_SWIDTH=$_tuish_swidth
}

# ─── Codepoint width classification ──────────────────────────────
# $1 = codepoint (decimal). Sets _tuish_cw.
# 0 for combining/control, 2 for wide/fullwidth, 1 otherwise.

_tuish_char_width ()
{
	if test $1 -lt 32
	then
		_tuish_cw=0
	elif test $1 -lt 127
	then
		_tuish_cw=1
	elif test $1 -lt 160
	then
		_tuish_cw=0
	elif test $1 -lt 768
	then
		_tuish_cw=1
	elif test $1 -lt 880
	then
		# Combining Diacritical Marks (U+0300-U+036F)
		_tuish_cw=0
	elif test $1 -lt 4352
	then
		_tuish_cw=1
	elif test $1 -lt 4448
	then
		# Hangul Jamo (U+1100-U+115F)
		_tuish_cw=2
	elif test $1 -lt 8203
	then
		# Check specific zero-width and combining ranges
		if test $1 -ge 6832 && test $1 -le 6911
		then
			_tuish_cw=0  # Combining Diacritical Marks Extended (U+1AB0-U+1AFF)
		elif test $1 -ge 7616 && test $1 -le 7679
		then
			_tuish_cw=0  # Combining Diacritical Marks Supplement (U+1DC0-U+1DFF)
		elif test $1 -ge 8400 && test $1 -le 8447
		then
			_tuish_cw=0  # Combining Diacritical Marks for Symbols (U+20D0-U+20FF)
		else
			_tuish_cw=1
		fi
		return
	elif test $1 -le 8207
	then
		_tuish_cw=0  # Zero-width space, ZWNJ, ZWJ, LRM, RLM
	elif test $1 -lt 8986
	then
		if test $1 -ge 8400 && test $1 -le 8447
		then
			_tuish_cw=0  # Combining marks for symbols
		else
			_tuish_cw=1
		fi
	elif test $1 -le 8987
	then
		_tuish_cw=2  # ⌚⌛ (U+231A-U+231B)
	elif test $1 -lt 11904
	then
		# Emoji-presentation characters (terminals render width 2)
		if test $1 -ge 9725 && test $1 -le 9726
		then
			_tuish_cw=2  # ◽◾ (U+25FD-U+25FE)
		elif test $1 -ge 9748 && test $1 -le 9749
		then
			_tuish_cw=2  # ☔☕ (U+2614-U+2615)
		elif test $1 -ge 9800 && test $1 -le 9811
		then
			_tuish_cw=2  # ♈-♓ zodiac (U+2648-U+2653)
		elif test $1 -eq 9855
		then
			_tuish_cw=2  # ♿ (U+267F)
		elif test $1 -eq 9875
		then
			_tuish_cw=2  # ⚓ (U+2693)
		elif test $1 -eq 9889
		then
			_tuish_cw=2  # ⚡ (U+26A1)
		elif test $1 -ge 9898 && test $1 -le 9899
		then
			_tuish_cw=2  # ⚪⚫ (U+26AA-U+26AB)
		elif test $1 -ge 9917 && test $1 -le 9918
		then
			_tuish_cw=2  # ⚽⚾ (U+26BD-U+26BE)
		elif test $1 -ge 9924 && test $1 -le 9925
		then
			_tuish_cw=2  # ⛄⛅ (U+26C4-U+26C5)
		elif test $1 -eq 9934
		then
			_tuish_cw=2  # ⛎ (U+26CE)
		elif test $1 -eq 9940
		then
			_tuish_cw=2  # ⛔ (U+26D4)
		elif test $1 -eq 9962
		then
			_tuish_cw=2  # ⛪ (U+26EA)
		elif test $1 -ge 9970 && test $1 -le 9971
		then
			_tuish_cw=2  # ⛲⛳ (U+26F2-U+26F3)
		elif test $1 -eq 9973
		then
			_tuish_cw=2  # ⛵ (U+26F5)
		elif test $1 -eq 9978
		then
			_tuish_cw=2  # ⛺ (U+26FA)
		elif test $1 -eq 9981
		then
			_tuish_cw=2  # ⛽ (U+26FD)
		elif test $1 -eq 10024
		then
			_tuish_cw=2  # ✨ (U+2728)
		elif test $1 -ge 10060 && test $1 -le 10062
		then
			_tuish_cw=2  # ❌❍❎ (U+274C-U+274E)
		elif test $1 -ge 10067 && test $1 -le 10069
		then
			_tuish_cw=2  # ❓❔❕ (U+2753-U+2755)
		elif test $1 -eq 10071
		then
			_tuish_cw=2  # ❗ (U+2757)
		elif test $1 -ge 10133 && test $1 -le 10135
		then
			_tuish_cw=2  # ➕➖➗ (U+2795-U+2797)
		elif test $1 -eq 10145
		then
			_tuish_cw=2  # ➡ (U+27A1)
		elif test $1 -eq 10160
		then
			_tuish_cw=2  # ➰ (U+27B0)
		elif test $1 -eq 10175
		then
			_tuish_cw=2  # ➿ (U+27BF)
		elif test $1 -ge 11035 && test $1 -le 11036
		then
			_tuish_cw=2  # ⬛⬜ (U+2B1B-U+2B1C)
		elif test $1 -eq 11088
		then
			_tuish_cw=2  # ⭐ (U+2B50)
		elif test $1 -eq 11093
		then
			_tuish_cw=2  # ⭕ (U+2B55)
		elif test $1 -ge 8400 && test $1 -le 8447
		then
			_tuish_cw=0  # Combining marks for symbols (U+20D0-U+20FF)
		else
			_tuish_cw=1
		fi
	elif test $1 -lt 12352
	then
		# CJK Radicals, Kangxi, Ideographic, Bopomofo, etc.
		_tuish_cw=2
	elif test $1 -lt 12448
	then
		# Hiragana (U+3040-U+309F)
		_tuish_cw=2
	elif test $1 -lt 12544
	then
		# Katakana (U+30A0-U+30FF)
		_tuish_cw=2
	elif test $1 -lt 12592
	then
		_tuish_cw=2  # Bopomofo Extended, CJK Strokes
	elif test $1 -lt 12688
	then
		# Hangul Compatibility Jamo
		_tuish_cw=2
	elif test $1 -lt 12784
	then
		# Kanbun, CJK Strokes
		_tuish_cw=2
	elif test $1 -lt 12800
	then
		# Katakana Phonetic Ext
		_tuish_cw=2
	elif test $1 -lt 19904
	then
		# Enclosed CJK, CJK Compat, CJK Ext A, Yijing
		_tuish_cw=2
	elif test $1 -lt 19968
	then
		_tuish_cw=1
	elif test $1 -lt 40960
	then
		# CJK Unified Ideographs (U+4E00-U+9FFF)
		_tuish_cw=2
	elif test $1 -lt 44032
	then
		# Yi, Lisu, Vai (mostly single)
		_tuish_cw=1
	elif test $1 -lt 55216
	then
		# Hangul Syllables (U+AC00-U+D7AF)
		_tuish_cw=2
	elif test $1 -lt 63744
	then
		_tuish_cw=1
	elif test $1 -lt 64256
	then
		# CJK Compatibility Ideographs (U+F900-U+FAFF)
		_tuish_cw=2
	elif test $1 -lt 65024
	then
		_tuish_cw=1
	elif test $1 -lt 65040
	then
		# Variation Selectors (U+FE00-U+FE0F)
		_tuish_cw=0
	elif test $1 -lt 65072
	then
		_tuish_cw=1
	elif test $1 -lt 65136
	then
		# CJK Compatibility Forms, Small Form Variants (U+FE30-U+FE6F)
		_tuish_cw=2
	elif test $1 -lt 65281
	then
		_tuish_cw=1
	elif test $1 -lt 65377
	then
		# Fullwidth Latin (U+FF01-U+FF60)
		_tuish_cw=2
	elif test $1 -lt 65504
	then
		# Halfwidth forms (U+FF61-U+FFDF)
		_tuish_cw=1
	elif test $1 -lt 65511
	then
		# Fullwidth signs (U+FFE0-U+FFE6)
		_tuish_cw=2
	elif test $1 -ge 65529 && test $1 -le 65531
	then
		_tuish_cw=0  # Interlinear annotations (U+FFF9-U+FFFB)
	elif test $1 -ge 917760 && test $1 -le 917999
	then
		_tuish_cw=0  # Variation Selectors Supplement (U+E0100-U+E01EF)
	elif test $1 -ge 127744 && test $1 -le 129791
	then
		_tuish_cw=2  # Emoticons, Misc Symbols, etc.
	elif test $1 -ge 131072 && test $1 -le 196607
	then
		_tuish_cw=2  # CJK Ext B-F, Compat Supplement (U+20000-U+2FFFF)
	elif test $1 -ge 196608 && test $1 -le 262143
	then
		_tuish_cw=2  # CJK Ext G-I (U+30000-U+3FFFF)
	else
		_tuish_cw=1
	fi
}

# ─── UTF-8 byte-level decoding ───────────────────────────────────
# Manual UTF-8 decoding from raw bytes under LC_ALL=C.

# Get unsigned byte value at byte offset $2 in variable named $1.
# Result in _tuish_bval. Returns 1 (false) at end of string.
_tuish_byte_val ()
{
	eval "local _bv_ch=\"\${$1:$2:1}\""
	if test -z "$_bv_ch"; then _tuish_bval=0; return 1; fi
	_tuish_ord "$_bv_ch"
	_tuish_bval=$_tuish_code
	if test $_tuish_bval -lt 0; then _tuish_bval=$((_tuish_bval + 256)); fi
}

# Advance past one UTF-8 lead byte, setting _tuish_cbytes.
_tuish_utf8_len ()
{
	if test $1 -lt 128; then   _tuish_cbytes=1
	elif test $1 -lt 224; then _tuish_cbytes=2
	elif test $1 -lt 240; then _tuish_cbytes=3
	else                       _tuish_cbytes=4
	fi
}

# Decode UTF-8 codepoint at byte offset $2 in variable named $1.
# Sets _tuish_code (codepoint) and _tuish_cbytes (byte length).
# Returns 1 at end of string.
_tuish_utf8_decode ()
{
	_tuish_byte_val "$1" "$2" || return 1
	local _ud_b0=$_tuish_bval
	if test $_ud_b0 -lt 128
	then
		_tuish_code=$_ud_b0
		_tuish_cbytes=1
	elif test $_ud_b0 -lt 224
	then
		_tuish_byte_val "$1" "$(($2 + 1))"
		_tuish_code=$(( (_ud_b0 & 31) * 64 + (_tuish_bval & 63) ))
		_tuish_cbytes=2
	elif test $_ud_b0 -lt 240
	then
		_tuish_byte_val "$1" "$(($2 + 1))"
		local _ud_b1=$_tuish_bval
		_tuish_byte_val "$1" "$(($2 + 2))"
		_tuish_code=$(( (_ud_b0 & 15) * 4096 + (_ud_b1 & 63) * 64 + (_tuish_bval & 63) ))
		_tuish_cbytes=3
	else
		_tuish_byte_val "$1" "$(($2 + 1))"
		local _ud_b1=$_tuish_bval
		_tuish_byte_val "$1" "$(($2 + 2))"
		local _ud_b2=$_tuish_bval
		_tuish_byte_val "$1" "$(($2 + 3))"
		_tuish_code=$(( (_ud_b0 & 7) * 262144 + (_ud_b1 & 63) * 4096 + (_ud_b2 & 63) * 64 + (_tuish_bval & 63) ))
		_tuish_cbytes=4
	fi
}

# Find byte offset of character index $2 in variable named $1.
# Result in _tuish_boff.
_tuish_char_byte_off ()
{
	local _bo_i=0 _bo_ci=0
	while test $_bo_ci -lt $2
	do
		_tuish_byte_val "$1" $_bo_i || break
		_tuish_utf8_len $_tuish_bval
		_bo_i=$((_bo_i + _tuish_cbytes))
		_bo_ci=$((_bo_ci + 1))
	done
	_tuish_boff=$_bo_i
}
