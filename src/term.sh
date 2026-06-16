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
#   Clipping:   tuish_clip_reset
#   Scrolling:  tuish_scroll_region, tuish_scroll_up/down, tuish_scroll_up_n/down_n
#   Screen:     tuish_altscreen_on/off, tuish_newline
#   Attributes: tuish_sgr, tuish_sgr_reset, tuish_style,
#               tuish_bold/dim/italic/underline/blink/reverse/strikethrough
#   Colors:     tuish_fg/bg (0-7 basic, 8-15 bright, 16-255 palette,
#               R:G:B truecolor, or 'default')
#   Movement:   tuish_move_up/down/left/right
#
# Dependencies: tui.sh (_tuish_write, tuish_begin/end/flush,
#   tuish_show/hide_cursor, tuish_save/restore_cursor, tuish_reset_scroll)

# ─── Drawing primitives ──────────────────────────────────────────

tuish_move ()           { _tuish_cursor_abs_row=$1; _tuish_clipped=0; _tuish_write "\033[${1};${2}H"; }
tuish_vmove ()
{
	if test $_tuish_canvas_on -eq 0
	then
		# Hot path (no canvas): viewport translate + bottom clip, unchanged.
		local _abs=$((TUISH_VIEW_TOP + $1 - 1))
		if test $_abs -gt $TUISH_LINES
		then
			_tuish_clipped=1
			return 1
		fi
		_tuish_cursor_abs_row=$_abs
		_tuish_clipped=0
		_tuish_write "\033[$_tuish_cursor_abs_row;${2}H"
		return 0
	fi
	# Canvas active: $1/$2 are canvas-local CELL coords (1-based). Clip to the
	# canvas bounds (all four edges), then scale by the cell size and offset to
	# an absolute terminal position. Column clipping is by start cell; with
	# CW>1 content is assumed cell-aligned (one glyph per cell).
	if test $1 -lt 1 || test $1 -gt $TUISH_CANVAS_H \
	   || test $2 -lt 1 || test $2 -gt $TUISH_CANVAS_W
	then
		_tuish_clipped=1
		return 1
	fi
	local _abs=$((_tuish_canvas_row0 + ($1 - 1) * _tuish_canvas_ch + 1))
	local _col=$((_tuish_canvas_col0 + ($2 - 1) * _tuish_canvas_cw + 1))
	if test $_abs -gt $TUISH_LINES
	then
		_tuish_clipped=1
		return 1
	fi
	_tuish_cursor_abs_row=$_abs
	_tuish_clipped=0
	_tuish_write "\033[$_abs;${_col}H"
	return 0
}
tuish_print ()
{
	local _p="$1"
	case "$_p" in *'\'*) _p="${_p//\\/\\\\}";; esac
	test $_tuish_printf -eq 1 && case "$_p" in *%*) _p="${_p//\%/%%}";; esac
	_tuish_write "$_p"
}
tuish_print_at ()       { if tuish_vmove "$1" "$2"; then tuish_print "$3"; fi; _tuish_clipped=0; }
# Re-enable output after a hand-rolled `tuish_vmove`-guarded block. A clipped
# (off-screen) `tuish_vmove` leaves the guard set so the block's writes are
# suppressed; call this once the block ends to clear it, exactly as
# `tuish_print_at` does for the single-text case. Apps must use this rather
# than touching the private clip flag directly.
tuish_clip_reset ()     { _tuish_clipped=0; }
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

# Colors — one parser, two smart entry points. _tuish_color_params ROLE VALUE
# sets _tuish_cparams to the SGR parameter fragment (no leading ';' or 'm').
# ROLE is fg or bg. VALUE: '' (none), 0-7 basic, 8-15 bright, 16-255 palette,
# R:G:B truecolor, or 'default' (reset just this role). Shared by tuish_fg/bg,
# tuish_style, and draw.sh so the color grammar lives in exactly one place.
_tuish_color_params ()
{
	case "$2" in
		'')
			_tuish_cparams='';;
		default)
			if test "$1" = fg; then _tuish_cparams=39; else _tuish_cparams=49; fi;;
		*:*:*)
			local _cp_t="${2#*:}"
			if test "$1" = fg
			then _tuish_cparams="38;2;${2%%:*};${_cp_t%%:*};${_cp_t#*:}"
			else _tuish_cparams="48;2;${2%%:*};${_cp_t%%:*};${_cp_t#*:}"
			fi;;
		*)
			if test "$1" = fg
			then
				if test "$2" -lt 8;    then _tuish_cparams="3$2"
				elif test "$2" -lt 16; then _tuish_cparams="9$(($2 - 8))"
				else _tuish_cparams="38;5;$2"
				fi
			else
				if test "$2" -lt 8;    then _tuish_cparams="4$2"
				elif test "$2" -lt 16; then _tuish_cparams="10$(($2 - 8))"
				else _tuish_cparams="48;5;$2"
				fi
			fi;;
	esac
}
tuish_fg ()             { _tuish_color_params fg "$1"; _tuish_write "\033[${_tuish_cparams}m"; }
tuish_bg ()             { _tuish_color_params bg "$1"; _tuish_write "\033[${_tuish_cparams}m"; }

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
	if test -n "$_s_fg"; then _tuish_color_params fg "$_s_fg"; _s_seq="${_s_seq};${_tuish_cparams}"; fi
	if test -n "$_s_bg"; then _tuish_color_params bg "$_s_bg"; _s_seq="${_s_seq};${_tuish_cparams}"; fi
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
	local _cr_r=$1 _cr_c=$2 _cr_w=$3 _cr_h=$4 _cr_i=0
	# Row of _cr_w spaces via the shared base-module primitive (term.sh and
	# str.sh both build repeated strings but each depends only on tui.sh).
	_tuish_repeat ' ' "$_cr_w"
	local _cr_spaces=$_tuish_rep
	while test $_cr_i -lt $_cr_h; do
		if tuish_vmove $((_cr_r + _cr_i)) "$_cr_c"
		then _tuish_write "$_cr_spaces"
		fi
		_cr_i=$((_cr_i + 1))
	done
	_tuish_clipped=0
}
