# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/term.sh - Terminal output and drawing primitives
# Optional module. Source after tui.sh.
#
# Provides:
#   Cursor:     tuish_move, tuish_vmove, tuish_print, tuish_print_at
#   Clearing:   tuish_clear_line, tuish_clear_to_eol, tuish_clear_to_bol,
#               tuish_clear_screen, tuish_clear_region
#   Cursor:     tuish_cursor_shape
#   Scrolling:  tuish_scroll_region, tuish_scroll_up/down, tuish_scroll_up_n/down_n
#   Screen:     tuish_altscreen_on/off, tuish_newline
#   Attributes: tuish_sgr, tuish_sgr_reset, tuish_style,
#               tuish_bold/dim/italic/underline/blink/reverse/strikethrough
#   Colors:     tuish_fg/bg, tuish_fg_bright/bg_bright, tuish_fg256/bg256,
#               tuish_fg_rgb/bg_rgb, tuish_fg_default/bg_default
#   Movement:   tuish_move_up/down/left/right
#
# Dependencies: tui.sh (_tuish_write, tuish_begin/end/flush,
#   tuish_show/hide_cursor, tuish_save/restore_cursor, tuish_reset_scroll)

# ─── Drawing primitives ──────────────────────────────────────────

tuish_move ()           { _tuish_cursor_abs_row=$1; _tuish_clipped=0; _tuish_write "\033[${1};${2}H"; }
tuish_vmove ()
{
	local _abs=$((TUISH_VIEW_TOP + $1 - 1))
	if test $_abs -gt $TUISH_LINES
	then
		_tuish_clipped=1
		return 1
	fi
	_tuish_cursor_abs_row=$_abs
	_tuish_clipped=0
	_tuish_write "\033[$_tuish_cursor_abs_row;${2}H"
}
tuish_print ()
{
	local _p="$1"
	case "$_p" in *'\'*) _p="${_p//\\/\\\\}";; esac
	test $_tuish_printf -eq 1 && case "$_p" in *%*) _p="${_p//%/%%}";; esac
	_tuish_write "$_p"
}
tuish_print_at ()       { tuish_vmove "$1" "$2"; tuish_print "$3"; }
tuish_clear_line ()     { _tuish_write '\033[2K'; }
tuish_clear_to_eol ()   { _tuish_write '\033[K'; }
tuish_clear_screen ()   { _tuish_write '\033[2J'; }
tuish_cursor ()
{
	_tuish_cursor_vrow=0
	_tuish_cursor_vcol=0
	if tuish_vmove "$1" "$2"
	then
		_tuish_cursor_vrow=$1
		_tuish_cursor_vcol=$2
		tuish_show_cursor
	fi
}
tuish_scroll_region ()  { _tuish_write "\033[${1};${2}r"; }
tuish_sgr ()            { _tuish_write "\033[${1}m"; }
tuish_sgr_reset ()      { _tuish_write '\033[0m'; }
tuish_altscreen_on ()   { _tuish_write '\033[?1049h'; }
tuish_altscreen_off ()  { _tuish_write '\033[?1049l'; }
tuish_scroll_up ()      { _tuish_write '\033[S'; }
tuish_scroll_down ()    { _tuish_write '\033[T'; }
tuish_scroll_up_n ()    { _tuish_write "\033[${1}S"; }
tuish_scroll_down_n ()  { _tuish_write "\033[${1}T"; }
tuish_newline ()        { _tuish_write '\n\r'; }
tuish_clear_to_bol ()   { _tuish_write '\033[1K'; }

# Text attributes
tuish_bold ()           { _tuish_write '\033[1m'; }
tuish_dim ()            { _tuish_write '\033[2m'; }
tuish_italic ()         { _tuish_write '\033[3m'; }
tuish_underline ()      { _tuish_write '\033[4m'; }
tuish_blink ()          { _tuish_write '\033[5m'; }
tuish_reverse ()        { _tuish_write '\033[7m'; }
tuish_strikethrough ()  { _tuish_write '\033[9m'; }

# Colors — basic (0-7: black red green yellow blue magenta cyan white)
tuish_fg ()             { _tuish_write "\033[3${1}m"; }
tuish_bg ()             { _tuish_write "\033[4${1}m"; }
tuish_fg_bright ()      { _tuish_write "\033[9${1}m"; }
tuish_bg_bright ()      { _tuish_write "\033[10${1}m"; }

# Colors — 256 palette
tuish_fg256 ()          { _tuish_write "\033[38;5;${1}m"; }
tuish_bg256 ()          { _tuish_write "\033[48;5;${1}m"; }

# Colors — truecolor (R G B)
tuish_fg_rgb ()         { _tuish_write "\033[38;2;${1};${2};${3}m"; }
tuish_bg_rgb ()         { _tuish_write "\033[48;2;${1};${2};${3}m"; }

# Colors — reset to terminal default
tuish_fg_default ()     { _tuish_write '\033[39m'; }
tuish_bg_default ()     { _tuish_write '\033[49m'; }

# Combined style: tuish_style [bold] [dim] [italic] [underline] [reverse] [fg=N] [bg=N]
# Emits a single SGR reset + combined sequence. Color accepts 0-7 (basic),
# 8-15 (bright), 16-255 (256-palette), or R:G:B (truecolor).
tuish_style ()
{
	local _s_seq='0'
	local _s_fg='' _s_bg=''
	while test $# -gt 0; do
		case "$1" in
			bold)          _s_seq="${_s_seq};1";;
			dim)           _s_seq="${_s_seq};2";;
			italic)        _s_seq="${_s_seq};3";;
			underline)     _s_seq="${_s_seq};4";;
			blink)         _s_seq="${_s_seq};5";;
			reverse)       _s_seq="${_s_seq};7";;
			strikethrough) _s_seq="${_s_seq};9";;
			fg=*)          _s_fg="${1#*=}";;
			bg=*)          _s_bg="${1#*=}";;
		esac
		shift
	done
	# Foreground
	if test -n "$_s_fg"; then
		case "$_s_fg" in
			*:*:*)
				local _r="${_s_fg%%:*}" _rest="${_s_fg#*:}"
				_s_seq="${_s_seq};38;2;${_r};${_rest%%:*};${_rest#*:}";;
			*)
				if test "$_s_fg" -lt 8;        then _s_seq="${_s_seq};3${_s_fg}"
				elif test "$_s_fg" -lt 16;     then _s_seq="${_s_seq};9$((_s_fg - 8))"
				else _s_seq="${_s_seq};38;5;${_s_fg}"
				fi;;
		esac
	fi
	# Background
	if test -n "$_s_bg"; then
		case "$_s_bg" in
			*:*:*)
				local _r="${_s_bg%%:*}" _rest="${_s_bg#*:}"
				_s_seq="${_s_seq};48;2;${_r};${_rest%%:*};${_rest#*:}";;
			*)
				if test "$_s_bg" -lt 8;        then _s_seq="${_s_seq};4${_s_bg}"
				elif test "$_s_bg" -lt 16;     then _s_seq="${_s_seq};10$((_s_bg - 8))"
				else _s_seq="${_s_seq};48;5;${_s_bg}"
				fi;;
		esac
	fi
	_tuish_write "\033[${_s_seq}m"
}

# Cursor shape (DECSCUSR): 0=default 1=blink-block 2=block 3=blink-underline 4=underline 5=blink-bar 6=bar
tuish_cursor_shape ()   { _tuish_write "\033[${1} q"; }

# Relative cursor movement (default: 1 cell)
tuish_move_up ()        { _tuish_write "\033[${1:-1}A"; }
tuish_move_down ()      { _tuish_write "\033[${1:-1}B"; }
tuish_move_right ()     { _tuish_write "\033[${1:-1}C"; }
tuish_move_left ()      { _tuish_write "\033[${1:-1}D"; }

# tuish_clear_region ROW COL W H
# Clear a rectangular area by writing spaces.
tuish_clear_region ()
{
	local _cr_r=$1 _cr_c=$2 _cr_w=$3 _cr_h=$4 _cr_i=0 _cr_j=0
	local _cr_spaces=''
	while test $_cr_j -lt "$_cr_w"; do
		_cr_spaces="${_cr_spaces} "
		_cr_j=$((_cr_j + 1))
	done
	while test $_cr_i -lt $_cr_h; do
		tuish_vmove $((_cr_r + _cr_i)) "$_cr_c"
		_tuish_write "$_cr_spaces"
		_cr_i=$((_cr_i + 1))
	done
}
