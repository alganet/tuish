# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/compat.sh - Shell compatibility layer
# Source first, before any other module.  Do not execute directly.
#
# Provides:
#   Shell options    - set -euf, zsh POSIX compat unsetopt
#   _tuish_printf   - 1 if printf is usable for output, 0 for mksh (use echo -ne)
#   _tuish_out()    - raw terminal output (printf or echo -ne depending on shell)
#   alias local      - ksh93 compatibility (local → typeset)

# ─── Shell options ───────────────────────────────────────────────

set -euf
unsetopt NO_POSIX_TRAPS FLOW_CONTROL GLOB NO_MATCH NO_SH_WORD_SPLIT NO_PROMPT_SUBST 2>/dev/null || :

# ─── Locale ──────────────────────────────────────────────────────
# Force byte-oriented locale for consistent string operations across
# all shells.

_tuish_orig_lang="${LANG:-}"
_tuish_orig_lc_all="${LC_ALL:-}"
_tuish_orig_lc_ctype="${LC_CTYPE:-}"
LC_ALL=C; export LC_ALL
LC_CTYPE=C; export LC_CTYPE

# ─── Shell detection ──────────────────────────────────────────────

_tuish_printf=1

_tuish_out ()
{
	printf "${1:-}"
}

if test -n "${KSH_VERSION:-}"
then
	if test -z "${KSH_VERSION##*Version AJM*}"
	then
		alias local=typeset
	fi
	if test -z "${KSH_VERSION##*MIRBSD*}"
	then
		_tuish_printf=0
		_tuish_out ()
		{
			echo -ne "${1:-}"
		}
	fi
fi

