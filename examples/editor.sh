#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# editor.sh - CUA-like text editor using tui.sh
# Ctrl+W to exit.

_dir="$(cd "$(dirname "$0")" && pwd)"
_tuish_src_dir="${_dir}/../src"
. "${_tuish_src_dir}/compat.sh"
. "${_tuish_src_dir}/ord.sh"
. "${_tuish_src_dir}/tui.sh"
. "${_tuish_src_dir}/term.sh"
. "${_tuish_src_dir}/event.sh"
. "${_tuish_src_dir}/hid.sh"
. "${_tuish_src_dir}/viewport.sh"
. "${_tuish_src_dir}/str.sh"
. "${_tuish_src_dir}/buf.sh"
. "${_tuish_src_dir}/keybind.sh"

# ─── Editor state ───────────────────────────────────────────────────

_cur_row=1
_cur_col=1
_view_top=1
_view_left=0     # horizontal scroll offset (0-based)
_view_height=0
_view_width=0
_sel_row=0       # 0 = no selection
_sel_col=0
_status_msg=''

# ─── Cursor helpers ─────────────────────────────────────────────────

_clamp_col ()
{
	tuish_buf_get $_cur_row; local _line="$_tuish_bline"
	tuish_str_len _line
	if test $_cur_col -gt $((_tuish_slen + 1))
	then
		_cur_col=$((_tuish_slen + 1))
	fi
	test $_cur_col -lt 1 && _cur_col=1
}

_ensure_visible ()
{
	if test $_cur_row -lt $_view_top
	then
		_view_top=$_cur_row
		tuish_request_redraw
	elif test $_cur_row -ge $((_view_top + _view_height))
	then
		_view_top=$((_cur_row - _view_height + 1))
		tuish_request_redraw
	fi
	# Horizontal scrolling
	if test $_cur_col -le $_view_left
	then
		_view_left=$((_cur_col - 1))
		test $_view_left -lt 0 && _view_left=0
		tuish_request_redraw
	elif test $_cur_col -gt $((_view_left + _view_width))
	then
		_view_left=$((_cur_col - _view_width))
		tuish_request_redraw
	fi
}

_clear_sel ()
{
	if test $_sel_row -ne 0
	then
		_sel_row=0
		_sel_col=0
		tuish_request_redraw
	fi
}

_start_sel ()
{
	if test $_sel_row -eq 0
	then
		_sel_row=$_cur_row
		_sel_col=$_cur_col
	fi
}

# ─── Word navigation ────────────────────────────────────────────────

_word_left ()
{
	tuish_buf_get $_cur_row; local _line="$_tuish_bline"
	if test $_cur_col -le 1
	then
		# Move to end of previous line
		if test $_cur_row -gt 1
		then
			_cur_row=$((_cur_row - 1))
			tuish_buf_get $_cur_row; _line="$_tuish_bline"
			tuish_str_len _line
			_cur_col=$((_tuish_slen + 1))
		fi
		return
	fi

	# O(n) via parameter expansion instead of O(n²) char-by-char
	tuish_str_left _line $((_cur_col - 1))
	local _before="$_tuish_sleft"

	# Strip trailing whitespace
	local _trail_ws="${_before##*[! 	]}"
	local _no_ws="${_before%"$_trail_ws"}"

	# All whitespace or empty → go to column 1
	if test -z "$_no_ws"
	then
		_cur_col=1
		return
	fi

	# Strip trailing word chars (find last whitespace boundary)
	case "$_no_ws" in
		*' '*|*'	'*)
			local _trail_word="${_no_ws##*[ 	]}"
			_no_ws="${_no_ws%"$_trail_word"}"
			;;
		*)
			# No whitespace: word starts at beginning of line
			_cur_col=1
			return
			;;
	esac

	tuish_str_len _no_ws
	_cur_col=$((_tuish_slen + 1))
}

_word_right ()
{
	tuish_buf_get $_cur_row; local _line="$_tuish_bline"
	tuish_str_len _line
	local _len=$_tuish_slen

	if test $_cur_col -gt $_len
	then
		if test $_cur_row -lt $TUISH_BUF_COUNT
		then
			_cur_row=$((_cur_row + 1))
			_cur_col=1
		fi
		return
	fi

	# O(n) via parameter expansion instead of O(n²) char-by-char
	tuish_str_right _line $((_cur_col - 1))
	local _after="$_tuish_sright"

	# Strip leading word chars (non-whitespace)
	local _lead_word="${_after%%[	 ]*}"
	local _rest="${_after#"$_lead_word"}"

	# Strip leading whitespace
	local _lead_ws="${_rest%%[!	 ]*}"

	tuish_str_len _lead_word
	local _wlen=$_tuish_slen
	tuish_str_len _lead_ws
	_cur_col=$((_cur_col + _wlen + _tuish_slen))
}

# ─── Selection helpers ──────────────────────────────────────────────

# Determine selection bounds: _sr1/_sc1 = start, _sr2/_sc2 = end
_sel_bounds ()
{
	if test $_sel_row -eq 0
	then
		_sr1=0; _sc1=0; _sr2=0; _sc2=0
		return
	fi

	if test $_sel_row -lt $_cur_row || {
		test $_sel_row -eq $_cur_row && test $_sel_col -le $_cur_col ;}
	then
		_sr1=$_sel_row; _sc1=$_sel_col
		_sr2=$_cur_row;  _sc2=$_cur_col
	else
		_sr1=$_cur_row;  _sc1=$_cur_col
		_sr2=$_sel_row; _sc2=$_sel_col
	fi
}

_delete_selection ()
{
	_sel_bounds
	test $_sr1 -eq 0 && return 1

	if test $_sr1 -eq $_sr2
	then
		# Same line: delete columns
		tuish_buf_get $_sr1; local _line="$_tuish_bline"
		tuish_str_left _line $((_sc1 - 1))
		local _left="$_tuish_sleft"
		tuish_str_right _line $((_sc2 - 1))
		tuish_buf_set $_sr1 "${_left}${_tuish_sright}"
	else
		# Multi-line: join first and last, delete middle
		tuish_buf_get $_sr1; local _first="$_tuish_bline"
		tuish_str_left _first $((_sc1 - 1))
		local _head="$_tuish_sleft"

		tuish_buf_get $_sr2; local _last="$_tuish_bline"
		tuish_str_right _last $((_sc2 - 1))
		local _tail="$_tuish_sright"

		tuish_buf_set $_sr1 "${_head}${_tail}"

		local _d=$_sr2
		while test $_d -gt $_sr1
		do
			tuish_buf_delete_at $((_sr1 + 1))
			_d=$((_d - 1))
		done
	fi

	_cur_row=$_sr1
	_cur_col=$_sc1
	_sel_row=0
	_sel_col=0
	tuish_request_redraw
}

# ─── Action functions (bound via tuish_bind) ─────────────────────

_ed_quit ()      { tuish_quit_clear; }

_ed_toggle_fullscreen ()
{
	if test "$TUISH_VIEW_MODE" = 'fullscreen'
	then
		tuish_viewport fixed 10
	else
		tuish_viewport fullscreen
	fi
	_view_height=$((TUISH_VIEW_ROWS - 1))
	_view_width=$TUISH_COLUMNS
	tuish_request_redraw
}

_ed_up ()        { _clear_sel; test $_cur_row -gt 1 && _cur_row=$((_cur_row - 1)); _clamp_col; }
_ed_down ()      { _clear_sel; test $_cur_row -lt $TUISH_BUF_COUNT && _cur_row=$((_cur_row + 1)); _clamp_col; }

_ed_left ()
{
	_clear_sel
	if test $_cur_col -gt 1
	then
		_cur_col=$((_cur_col - 1))
	elif test $_cur_row -gt 1
	then
		_cur_row=$((_cur_row - 1))
		tuish_buf_get $_cur_row; local _l="$_tuish_bline"; tuish_str_len _l
		_cur_col=$((_tuish_slen + 1))
	fi
}

_ed_right ()
{
	_clear_sel
	tuish_buf_get $_cur_row; local _l="$_tuish_bline"; tuish_str_len _l
	if test $_cur_col -le $_tuish_slen
	then
		_cur_col=$((_cur_col + 1))
	elif test $_cur_row -lt $TUISH_BUF_COUNT
	then
		_cur_row=$((_cur_row + 1))
		_cur_col=1
	fi
}

_ed_home ()      { _clear_sel; _cur_col=1; }

_ed_end ()
{
	_clear_sel
	tuish_buf_get $_cur_row; local _l="$_tuish_bline"; tuish_str_len _l
	_cur_col=$((_tuish_slen + 1))
}

_ed_word_left ()  { _clear_sel; _word_left; }
_ed_word_right () { _clear_sel; _word_right; }

_ed_top ()       { _clear_sel; _cur_row=1; _cur_col=1; }

_ed_bottom ()
{
	_clear_sel
	_cur_row=$TUISH_BUF_COUNT
	tuish_buf_get $_cur_row; local _l="$_tuish_bline"; tuish_str_len _l
	_cur_col=$((_tuish_slen + 1))
}

_ed_pgup ()
{
	_clear_sel
	_cur_row=$((_cur_row - _view_height))
	test $_cur_row -lt 1 && _cur_row=1
	_clamp_col
}

_ed_pgdn ()
{
	_clear_sel
	_cur_row=$((_cur_row + _view_height))
	test $_cur_row -gt $TUISH_BUF_COUNT && _cur_row=$TUISH_BUF_COUNT
	_clamp_col
}

# Selection navigation
_ed_sel_up ()
{
	_start_sel
	test $_cur_row -gt 1 && _cur_row=$((_cur_row - 1))
	_clamp_col; tuish_request_redraw
}

_ed_sel_down ()
{
	_start_sel
	test $_cur_row -lt $TUISH_BUF_COUNT && _cur_row=$((_cur_row + 1))
	_clamp_col; tuish_request_redraw
}

_ed_sel_left ()
{
	_start_sel
	if test $_cur_col -gt 1
	then
		_cur_col=$((_cur_col - 1))
	elif test $_cur_row -gt 1
	then
		_cur_row=$((_cur_row - 1))
		tuish_buf_get $_cur_row; local _l="$_tuish_bline"; tuish_str_len _l
		_cur_col=$((_tuish_slen + 1))
	fi
	tuish_request_redraw
}

_ed_sel_right ()
{
	_start_sel
	tuish_buf_get $_cur_row; local _l="$_tuish_bline"; tuish_str_len _l
	if test $_cur_col -le $_tuish_slen
	then
		_cur_col=$((_cur_col + 1))
	elif test $_cur_row -lt $TUISH_BUF_COUNT
	then
		_cur_row=$((_cur_row + 1)); _cur_col=1
	fi
	tuish_request_redraw
}

_ed_sel_home ()  { _start_sel; _cur_col=1; tuish_request_redraw; }

_ed_sel_end ()
{
	_start_sel
	tuish_buf_get $_cur_row; local _l="$_tuish_bline"; tuish_str_len _l
	_cur_col=$((_tuish_slen + 1)); tuish_request_redraw
}

_ed_sel_word_left ()  { _start_sel; _word_left; tuish_request_redraw; }
_ed_sel_word_right () { _start_sel; _word_right; tuish_request_redraw; }
_ed_sel_top ()        { _start_sel; _cur_row=1; _cur_col=1; tuish_request_redraw; }

_ed_sel_bottom ()
{
	_start_sel; _cur_row=$TUISH_BUF_COUNT
	tuish_buf_get $_cur_row; local _l="$_tuish_bline"; tuish_str_len _l
	_cur_col=$((_tuish_slen + 1)); tuish_request_redraw
}

# Mouse actions
_ed_click ()
{
	_clear_sel
	_cur_row=$((_view_top + TUISH_MOUSE_Y - 1))
	_cur_col=$((_view_left + TUISH_MOUSE_X))
	test $_cur_row -lt 1 && _cur_row=1
	test $_cur_row -gt $TUISH_BUF_COUNT && _cur_row=$TUISH_BUF_COUNT
	_clamp_col
}

_ed_drag ()
{
	if test $_sel_row -eq 0
	then
		_sel_row=$_cur_row
		_sel_col=$_cur_col
	fi
	_cur_row=$((_view_top + TUISH_MOUSE_Y - 1))
	_cur_col=$((_view_left + TUISH_MOUSE_X))
	test $_cur_row -lt 1 && _cur_row=1
	test $_cur_row -gt $TUISH_BUF_COUNT && _cur_row=$TUISH_BUF_COUNT
	_clamp_col
	tuish_request_redraw
}

_ed_scroll_up ()
{
	_view_top=$((_view_top - 3))
	test $_view_top -lt 1 && _view_top=1
	tuish_request_redraw
}

_ed_scroll_down ()
{
	_view_top=$((_view_top + 3))
	local _max=$((TUISH_BUF_COUNT - _view_height + 1))
	test $_max -lt 1 && _max=1
	test $_view_top -gt $_max && _view_top=$_max
	tuish_request_redraw
}

# Editing actions
_ed_insert_char ()
{
	local _ch="${TUISH_EVENT#char }"
	test "$_ch" = 'bslash' && _ch='\'
	test $_sel_row -ne 0 && _delete_selection
	tuish_buf_get $_cur_row; local _line="$_tuish_bline"
	tuish_str_left _line $((_cur_col - 1))
	local _left="$_tuish_sleft"
	tuish_str_right _line $((_cur_col - 1))
	tuish_buf_set $_cur_row "${_left}${_ch}${_tuish_sright}"
	_cur_col=$((_cur_col + 1))
	_ed_render_line_now
	tuish_request_redraw 1
}

_ed_space ()
{
	test $_sel_row -ne 0 && _delete_selection
	tuish_buf_get $_cur_row; local _line="$_tuish_bline"
	tuish_str_left _line $((_cur_col - 1))
	local _left="$_tuish_sleft"
	tuish_str_right _line $((_cur_col - 1))
	tuish_buf_set $_cur_row "${_left} ${_tuish_sright}"
	_cur_col=$((_cur_col + 1))
	_ed_render_line_now
	tuish_request_redraw 1
}

_ed_tab ()
{
	test $_sel_row -ne 0 && _delete_selection
	tuish_buf_get $_cur_row; local _line="$_tuish_bline"
	tuish_str_left _line $((_cur_col - 1))
	local _left="$_tuish_sleft"
	tuish_str_right _line $((_cur_col - 1))
	tuish_buf_set $_cur_row "${_left}    ${_tuish_sright}"
	_cur_col=$((_cur_col + 4))
	_ed_render_line_now
	tuish_request_redraw 1
}

_ed_enter ()
{
	test $_sel_row -ne 0 && _delete_selection
	tuish_buf_get $_cur_row; local _line="$_tuish_bline"
	tuish_str_left _line $((_cur_col - 1))
	local _left="$_tuish_sleft"
	tuish_str_right _line $((_cur_col - 1))
	local _right="$_tuish_sright"
	tuish_buf_set $_cur_row "$_left"
	tuish_buf_insert_at $((_cur_row + 1)) "$_right"
	_cur_row=$((_cur_row + 1))
	_cur_col=1
	tuish_request_redraw
}

_ed_bksp ()
{
	if test $_sel_row -ne 0
	then
		_delete_selection
	elif test $_cur_col -gt 1
	then
		tuish_buf_get $_cur_row; local _line="$_tuish_bline"
		tuish_str_left _line $((_cur_col - 2))
		local _left="$_tuish_sleft"
		tuish_str_right _line $((_cur_col - 1))
		tuish_buf_set $_cur_row "${_left}${_tuish_sright}"
		_cur_col=$((_cur_col - 1))
		_ed_render_line_now
		tuish_request_redraw 1
	elif test $_cur_row -gt 1
	then
		# Join with previous line
		tuish_buf_get $((_cur_row - 1)); local _prev="$_tuish_bline"
		tuish_buf_get $_cur_row; local _curr="$_tuish_bline"
		tuish_str_len _prev
		local _newcol=$((_tuish_slen + 1))
		tuish_buf_set $((_cur_row - 1)) "${_prev}${_curr}"
		tuish_buf_delete_at $_cur_row
		_cur_row=$((_cur_row - 1))
		_cur_col=$_newcol
		tuish_request_redraw
	fi
}

_ed_del ()
{
	if test $_sel_row -ne 0
	then
		_delete_selection
	else
		tuish_buf_get $_cur_row; local _line="$_tuish_bline"
		tuish_str_len _line
		if test $_cur_col -le $_tuish_slen
		then
			tuish_str_left _line $((_cur_col - 1))
			local _left="$_tuish_sleft"
			tuish_str_right _line $_cur_col
			tuish_buf_set $_cur_row "${_left}${_tuish_sright}"
			_ed_render_line_now
			tuish_request_redraw 1
		elif test $_cur_row -lt $TUISH_BUF_COUNT
		then
			# Join with next line
			tuish_buf_get $((_cur_row + 1)); local _next="$_tuish_bline"
			tuish_buf_set $_cur_row "${_line}${_next}"
			tuish_buf_delete_at $((_cur_row + 1))
			tuish_request_redraw
		fi
	fi
}

_ed_del_word_left ()
{
	if test $_sel_row -ne 0
	then
		_delete_selection
		return
	fi
	if test $_cur_col -le 1
	then
		# At start of line: join with previous (same as bksp)
		if test $_cur_row -gt 1
		then
			tuish_buf_get $((_cur_row - 1)); local _prev="$_tuish_bline"
			tuish_buf_get $_cur_row; local _curr="$_tuish_bline"
			tuish_str_len _prev
			local _newcol=$((_tuish_slen + 1))
			tuish_buf_set $((_cur_row - 1)) "${_prev}${_curr}"
			tuish_buf_delete_at $_cur_row
			_cur_row=$((_cur_row - 1))
			_cur_col=$_newcol
			tuish_request_redraw
		fi
		return
	fi
	local _old_col=$_cur_col
	_word_left
	tuish_buf_get $_cur_row; local _line="$_tuish_bline"
	tuish_str_left _line $((_cur_col - 1))
	local _left="$_tuish_sleft"
	tuish_str_right _line $((_old_col - 1))
	tuish_buf_set $_cur_row "${_left}${_tuish_sright}"
	_ed_render_line_now
	tuish_request_redraw 1
}

_ed_del_word_right ()
{
	if test $_sel_row -ne 0
	then
		_delete_selection
		return
	fi
	tuish_buf_get $_cur_row; local _line="$_tuish_bline"
	tuish_str_len _line
	if test $_cur_col -gt $_tuish_slen
	then
		# At end of line: join with next (same as del)
		if test $_cur_row -lt $TUISH_BUF_COUNT
		then
			tuish_buf_get $((_cur_row + 1)); local _next="$_tuish_bline"
			tuish_buf_set $_cur_row "${_line}${_next}"
			tuish_buf_delete_at $((_cur_row + 1))
			tuish_request_redraw
		fi
		return
	fi
	local _old_col=$_cur_col
	_word_right
	tuish_str_left _line $((_old_col - 1))
	local _left="$_tuish_sleft"
	tuish_str_right _line $((_cur_col - 1))
	tuish_buf_set $_cur_row "${_left}${_tuish_sright}"
	_cur_col=$_old_col
	_ed_render_line_now
	tuish_request_redraw 1
}

_ed_resize ()
{
	_view_height=$((TUISH_VIEW_ROWS - 1))
	test $_view_height -lt 0 && _view_height=0
	_view_width=$TUISH_COLUMNS
	test $_view_width -lt 1 && _view_width=1
	# Clear viewport to prevent rewrap garbage after width change
	local _i=1
	while test $_i -le $TUISH_VIEW_ROWS
	do
		tuish_vmove $_i 1
		tuish_clear_line
		_i=$((_i + 1))
	done
	tuish_request_redraw
}

_ed_noop () { :; }

_ed_show_unbound () { :; }

# ─── Rendering ──────────────────────────────────────────────────────

# Render current line immediately and flush to terminal.
# Use inside event handlers for latency-sensitive updates (typing).
# Deferred redraw (level 1) handles the status bar afterward.
_ed_render_line_now ()
{
	_render_line $_cur_row
	tuish_vmove $((_cur_row - _view_top + 1)) $((_cur_col - _view_left))
	tuish_flush
}

# Clip a line to the visible horizontal window (_view_left, _view_width).
# Outputs the visible portion of the line. Does not clear to EOL.
_render_clipped_line ()
{
	local _line="$1"
	tuish_str_len _line
	local _len=$_tuish_slen
	if test $_view_left -ge $_len
	then
		return
	fi
	tuish_str_right _line $_view_left
	local _visible="$_tuish_sright"
	tuish_str_len _visible
	if test $_tuish_slen -gt $_view_width
	then
		tuish_str_left _visible $_view_width
		tuish_print "$_tuish_sleft"
	else
		tuish_print "$_visible"
	fi
}

_render ()
{
	tuish_hide_cursor
	_sel_bounds

	# Text area
	local _vrow=1
	local _lnum=$_view_top
	local _line
	while test $_vrow -le $_view_height
	do
		tuish_vmove $_vrow 1

		if test $_lnum -le $TUISH_BUF_COUNT
		then
			tuish_buf_get $_lnum; _line="$_tuish_bline"

			# Check if this line has selection
			if test $_sr1 -ne 0 && test $_lnum -ge $_sr1 && test $_lnum -le $_sr2
			then
				_render_sel_line "$_lnum" "$_line"
			else
				_render_clipped_line "$_line"
			fi
		else
			tuish_sgr '2'
			tuish_print '~'
			tuish_sgr_reset
		fi
		tuish_clear_to_eol

		_vrow=$((_vrow + 1))
		_lnum=$((_lnum + 1))
	done

	# Status bar
	_render_status

	# Place cursor (adjusted for horizontal scroll)
	tuish_cursor $((_cur_row - _view_top + 1)) $((_cur_col - _view_left))
}

_render_sel_line ()
{
	local _lnum=$1
	local _line="$2"
	tuish_str_len _line
	local _len=$_tuish_slen

	# Selection bounds in character coordinates
	local _s=1 _e=$((_len + 1))
	test $_lnum -eq $_sr1 && _s=$_sc1
	test $_lnum -eq $_sr2 && _e=$_sc2

	# Visible window in character coordinates (1-based)
	local _vl=$((_view_left + 1))
	local _vr=$((_view_left + _view_width))

	# Clamp to visible window
	local _vs=$_s _ve=$_e
	test $_vs -lt $_vl && _vs=$_vl
	test $_ve -gt $((_vr + 1)) && _ve=$((_vr + 1))

	# Before selection (in visible window)
	if test $_vl -lt $_vs
	then
		local _bs=$((_vl - 1))
		local _bl=$((_vs - _vl))
		eval "local _bstr=\"\${_line:$_bs:$_bl}\""
		tuish_print "$_bstr"
	fi

	# Selected text (in visible window)
	if test $_ve -gt $_vs
	then
		tuish_sgr '7'
		local _sst=$((_vs - 1))
		local _ssl=$((_ve - _vs))
		eval "local _ssel=\"\${_line:$_sst:$_ssl}\""
		tuish_print "$_ssel"
		tuish_sgr_reset
	fi

	# After selection (in visible window)
	if test $_ve -le $_vr && test $_ve -le $((_len + 1))
	then
		local _as=$((_ve - 1))
		local _al=$((_vr - _ve + 1))
		test $((_as + _al)) -gt $_len && _al=$((_len - _as))
		if test $_al -gt 0
		then
			eval "local _astr=\"\${_line:$_as:$_al}\""
			tuish_print "$_astr"
		fi
	fi
}

_render_status ()
{
	tuish_vmove $TUISH_VIEW_ROWS 1
	tuish_sgr '7'
	local _w=$TUISH_COLUMNS
	test $_w -lt 1 && { tuish_sgr_reset; return; }
	local _info=" Ln ${_cur_row}, Col ${_cur_col}  |  ${TUISH_BUF_COUNT} lines "
	if test $_sel_row -ne 0
	then
		_info="${_info}  |  sel"
	fi
	if test -n "$_status_msg"
	then
		_info="${_info}  |  ${_status_msg}"
	fi
	if test "$TUISH_VIEW_MODE" = 'fullscreen'
	then
		local _help=' alt+f: short screen | ctrl+w: quit '
	else
		local _help=' alt+f: full screen | ctrl+w: quit '
	fi
	# Build a full-width status line padded with spaces so every cell
	# gets the reverse-video background (avoids terminal-dependent
	# clear_to_eol behaviour that can leave gaps).
	local _il=${#_info} _hl=${#_help}
	local _pad=$((_w - _il - _hl))
	if test $_pad -lt 0
	then
		# Not enough room for help text; truncate info to fit
		test $_il -ge $_w && _info="${_info:0:$((_w - 1))}"
		_il=${#_info}
		_pad=$((_w - _il))
		_help=''
		_hl=0
	fi
	tuish_print "$_info"
	# Emit padding spaces so the entire line has reverse-video background
	if test $_pad -gt 0
	then
		local _spaces='                                '  # 32 spaces
		while test ${#_spaces} -lt $_pad
		do
			_spaces="${_spaces}${_spaces}"
		done
		tuish_print "${_spaces:0:$_pad}"
	fi
	tuish_print "$_help"
	tuish_sgr_reset
	tuish_clear_to_eol
}

_render_line ()
{
	local _lnum=$1
	local _vrow=$((_lnum - _view_top + 1))
	# Skip if outside the text area (avoids overwriting status bar)
	test $_vrow -lt 1 && return
	test $_vrow -gt $_view_height && return
	tuish_vmove $_vrow 1
	if test $_lnum -le $TUISH_BUF_COUNT
	then
		tuish_buf_get $_lnum; local _rl_line="$_tuish_bline"
		_render_clipped_line "$_rl_line"
	else
		tuish_sgr '2'
		tuish_print '~'
		tuish_sgr_reset
	fi
	tuish_clear_to_eol
}

# ─── Key bindings ───────────────────────────────────────────────────

_ed_setup_bindings ()
{
	tuish_bind 'ctrl-w'          '_ed_quit'
	tuish_bind 'alt-f'           '_ed_toggle_fullscreen'

	# Navigation
	tuish_bind 'up'              '_ed_up'
	tuish_bind 'down'            '_ed_down'
	tuish_bind 'left'            '_ed_left'
	tuish_bind 'right'           '_ed_right'
	tuish_bind 'home'            '_ed_home'
	tuish_bind 'end'             '_ed_end'
	tuish_bind 'ctrl-left'       '_ed_word_left'
	tuish_bind 'ctrl-right'      '_ed_word_right'
	tuish_bind 'ctrl-home'       '_ed_top'
	tuish_bind 'ctrl-end'        '_ed_bottom'
	tuish_bind 'pgup'            '_ed_pgup'
	tuish_bind 'pgdn'            '_ed_pgdn'

	# Selection
	tuish_bind 'shift-up'         '_ed_sel_up'
	tuish_bind 'shift-down'       '_ed_sel_down'
	tuish_bind 'shift-left'       '_ed_sel_left'
	tuish_bind 'shift-right'      '_ed_sel_right'
	tuish_bind 'shift-home'       '_ed_sel_home'
	tuish_bind 'shift-end'        '_ed_sel_end'
	tuish_bind 'ctrl-shift-left'  '_ed_sel_word_left'
	tuish_bind 'ctrl-shift-right' '_ed_sel_word_right'
	tuish_bind 'ctrl-shift-home'  '_ed_sel_top'
	tuish_bind 'ctrl-shift-end'   '_ed_sel_bottom'

	# Mouse
	tuish_bind 'lclik'           '_ed_click'
	tuish_bind 'lhold'           '_ed_drag'
	tuish_bind 'whup'            '_ed_scroll_up'
	tuish_bind 'wdown'           '_ed_scroll_down'

	# Editing
	tuish_bind 'char *'          '_ed_insert_char'
	tuish_bind 'space'           '_ed_space'
	tuish_bind 'tab'             '_ed_tab'
	tuish_bind 'enter'           '_ed_enter'
	tuish_bind 'bksp'            '_ed_bksp'
	tuish_bind 'ctrl-bksp'       '_ed_del_word_left'
	tuish_bind 'del'             '_ed_del'
	tuish_bind 'ctrl-del'        '_ed_del_word_right'

	# Signals & misc
	tuish_bind 'resize'          '_ed_resize'
	tuish_bind 'focus-in'        '_ed_noop'
	tuish_bind 'focus-out'       '_ed_noop'
	tuish_bind 'idle'            '_ed_noop'

	# Catch-all: show unbound events in status bar
	tuish_bind '*'               '_ed_show_unbound'
}

# ─── Event handler ──────────────────────────────────────────────────

tuish_on_event ()
{
	_status_msg=''
	local _prev_row=$_cur_row
	local _prev_col=$_cur_col

	tuish_dispatch || :

	_ensure_visible

	# Cursor moved → at least status + cursor update
	if test $_cur_row -ne $_prev_row || test $_cur_col -ne $_prev_col
	then
		tuish_request_redraw 1
	fi
}

tuish_on_redraw ()
{
	if test "$1" -eq -1
	then
		_render
	elif test "$1" -ge 2
	then
		_render_line $_cur_row
		_render_status
		tuish_cursor $((_cur_row - _view_top + 1)) $((_cur_col - _view_left))
	else
		_render_status
		tuish_cursor $((_cur_row - _view_top + 1)) $((_cur_col - _view_left))
	fi
}

# ─── Main ───────────────────────────────────────────────────────────

_editor_main ()
{
	tuish_init
	tuish_cursor_shape 6          # steady bar cursor
	tuish_mouse_on

	_ed_setup_bindings

	tuish_viewport fixed 10

	_view_height=$((TUISH_VIEW_ROWS - 1))
	_view_width=$TUISH_COLUMNS

	# Load file from argv or start with empty buffer
	if test -n "${1:-}" && test -f "$1"
	then
		_status_msg="$1"
		while IFS= read -r _fline || test -n "$_fline"
		do
			tuish_buf_append "$_fline"
		done < "$1"
		test $TUISH_BUF_COUNT -eq 0 && tuish_buf_append ''
	else
		tuish_buf_init
	fi

	_render

	tuish_run || :

	tuish_cursor_shape 0          # restore default cursor
	tuish_fini
}

_editor_main "${@:-}"
