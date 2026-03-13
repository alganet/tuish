#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for _tuish_5code_modifiers and _tuish_6code_modifiers

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/event.sh"
. "$TESTS_DIR/../src/hid.sh"

_tuish_write () { :; }

TUISH_EVENT=''

printf 'Unit tests: modifier key detection\n'

# ============================================================
# _tuish_5code_modifiers: "91 <base> 59 <mod> <final>"
# Modifiers: 50=shift, 51=alt, 52=alt-shift, 53=ctrl, 54=ctrl-shift, 55=ctrl-alt, 56=ctrl-shift-alt
# ============================================================

printf '\n--- _tuish_5code_modifiers: arrow keys ---\n'

# Arrow keys: base=49, final: A=65 B=66 C=67 D=68
TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 50 65" '49' 'up' '65'
assert_eq "$TUISH_EVENT" "shift-up" "shift-up"

TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 51 65" '49' 'up' '65'
assert_eq "$TUISH_EVENT" "alt-up" "alt-up"

TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 52 65" '49' 'up' '65'
assert_eq "$TUISH_EVENT" "alt-shift-up" "alt-shift-up"

TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 53 65" '49' 'up' '65'
assert_eq "$TUISH_EVENT" "ctrl-up" "ctrl-up"

TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 54 65" '49' 'up' '65'
assert_eq "$TUISH_EVENT" "ctrl-shift-up" "ctrl-shift-up"

TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 55 65" '49' 'up' '65'
assert_eq "$TUISH_EVENT" "ctrl-alt-up" "ctrl-alt-up"

TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 56 65" '49' 'up' '65'
assert_eq "$TUISH_EVENT" "ctrl-alt-shift-up" "ctrl-shift-alt-up"

# Down
TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 53 66" '49' 'down' '66'
assert_eq "$TUISH_EVENT" "ctrl-down" "ctrl-down"

# Right
TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 53 67" '49' 'right' '67'
assert_eq "$TUISH_EVENT" "ctrl-right" "ctrl-right"

# Left
TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 53 68" '49' 'left' '68'
assert_eq "$TUISH_EVENT" "ctrl-left" "ctrl-left"

TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 51 67" '49' 'right' '67'
assert_eq "$TUISH_EVENT" "alt-right" "alt-right"

TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 50 68" '49' 'left' '68'
assert_eq "$TUISH_EVENT" "shift-left" "shift-left"

printf '\n--- _tuish_5code_modifiers: F1-F4 ---\n'

# F1: base=49, final=80
TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 53 80" '49' 'f1' '80'
assert_eq "$TUISH_EVENT" "ctrl-f1" "ctrl-f1"

TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 51 80" '49' 'f1' '80'
assert_eq "$TUISH_EVENT" "alt-f1" "alt-f1"

TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 50 80" '49' 'f1' '80'
assert_eq "$TUISH_EVENT" "shift-f1" "shift-f1"

# F2: base=49, final=81
TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 53 81" '49' 'f2' '81'
assert_eq "$TUISH_EVENT" "ctrl-f2" "ctrl-f2"

# F3: base=49, final=82
TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 53 82" '49' 'f3' '82'
assert_eq "$TUISH_EVENT" "ctrl-f3" "ctrl-f3"

# F4: base=49, final=83
TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 53 83" '49' 'f4' '83'
assert_eq "$TUISH_EVENT" "ctrl-f4" "ctrl-f4"

printf '\n--- _tuish_5code_modifiers: navigation keys ---\n'

# Home: base=49, final=72
TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 53 72" '49' 'home' '72'
assert_eq "$TUISH_EVENT" "ctrl-home" "ctrl-home"

TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 50 72" '49' 'home' '72'
assert_eq "$TUISH_EVENT" "shift-home" "shift-home"

# End: base=49, final=70
TUISH_EVENT=''; _tuish_5code_modifiers "91 49 59 53 70" '49' 'end' '70'
assert_eq "$TUISH_EVENT" "ctrl-end" "ctrl-end"

# Ins: base=50, final=126
TUISH_EVENT=''; _tuish_5code_modifiers "91 50 59 53 126" '50' 'ins' '126'
assert_eq "$TUISH_EVENT" "ctrl-ins" "ctrl-ins"

TUISH_EVENT=''; _tuish_5code_modifiers "91 50 59 50 126" '50' 'ins' '126'
assert_eq "$TUISH_EVENT" "shift-ins" "shift-ins"

# Del: base=51, final=126
TUISH_EVENT=''; _tuish_5code_modifiers "91 51 59 53 126" '51' 'del' '126'
assert_eq "$TUISH_EVENT" "ctrl-del" "ctrl-del"

TUISH_EVENT=''; _tuish_5code_modifiers "91 51 59 50 126" '51' 'del' '126'
assert_eq "$TUISH_EVENT" "shift-del" "shift-del"

# PgUp: base=53, final=126
TUISH_EVENT=''; _tuish_5code_modifiers "91 53 59 53 126" '53' 'pgup' '126'
assert_eq "$TUISH_EVENT" "ctrl-pgup" "ctrl-pgup"

# PgDn: base=54, final=126
TUISH_EVENT=''; _tuish_5code_modifiers "91 54 59 53 126" '54' 'pgdn' '126'
assert_eq "$TUISH_EVENT" "ctrl-pgdn" "ctrl-pgdn"

# ============================================================
# _tuish_6code_modifiers: "91 <base> <extra> 59 <mod> 126"
# ============================================================

printf '\n--- _tuish_6code_modifiers: F5-F12 ---\n'

# F5: base=49, extra=53
TUISH_EVENT=''; _tuish_6code_modifiers "91 49 53 59 50 126" '49' 'f5' '53'
assert_eq "$TUISH_EVENT" "shift-f5" "shift-f5"

TUISH_EVENT=''; _tuish_6code_modifiers "91 49 53 59 51 126" '49' 'f5' '53'
assert_eq "$TUISH_EVENT" "alt-f5" "alt-f5"

TUISH_EVENT=''; _tuish_6code_modifiers "91 49 53 59 52 126" '49' 'f5' '53'
assert_eq "$TUISH_EVENT" "alt-shift-f5" "alt-shift-f5"

TUISH_EVENT=''; _tuish_6code_modifiers "91 49 53 59 53 126" '49' 'f5' '53'
assert_eq "$TUISH_EVENT" "ctrl-f5" "ctrl-f5"

TUISH_EVENT=''; _tuish_6code_modifiers "91 49 53 59 54 126" '49' 'f5' '53'
assert_eq "$TUISH_EVENT" "ctrl-shift-f5" "ctrl-shift-f5"

TUISH_EVENT=''; _tuish_6code_modifiers "91 49 53 59 55 126" '49' 'f5' '53'
assert_eq "$TUISH_EVENT" "ctrl-alt-f5" "ctrl-alt-f5"

TUISH_EVENT=''; _tuish_6code_modifiers "91 49 53 59 56 126" '49' 'f5' '53'
assert_eq "$TUISH_EVENT" "ctrl-alt-shift-f5" "ctrl-shift-alt-f5"

# F6: base=49, extra=55
TUISH_EVENT=''; _tuish_6code_modifiers "91 49 55 59 53 126" '49' 'f6' '55'
assert_eq "$TUISH_EVENT" "ctrl-f6" "ctrl-f6"

# F7: base=49, extra=56
TUISH_EVENT=''; _tuish_6code_modifiers "91 49 56 59 53 126" '49' 'f7' '56'
assert_eq "$TUISH_EVENT" "ctrl-f7" "ctrl-f7"

# F8: base=49, extra=57
TUISH_EVENT=''; _tuish_6code_modifiers "91 49 57 59 53 126" '49' 'f8' '57'
assert_eq "$TUISH_EVENT" "ctrl-f8" "ctrl-f8"

# F9: base=50, extra=48
TUISH_EVENT=''; _tuish_6code_modifiers "91 50 48 59 53 126" '50' 'f9' '48'
assert_eq "$TUISH_EVENT" "ctrl-f9" "ctrl-f9"

# F10: base=50, extra=49
TUISH_EVENT=''; _tuish_6code_modifiers "91 50 49 59 53 126" '50' 'f10' '49'
assert_eq "$TUISH_EVENT" "ctrl-f10" "ctrl-f10"

# F11: base=50, extra=51
TUISH_EVENT=''; _tuish_6code_modifiers "91 50 51 59 53 126" '50' 'f11' '51'
assert_eq "$TUISH_EVENT" "ctrl-f11" "ctrl-f11"

# F12: base=50, extra=52
TUISH_EVENT=''; _tuish_6code_modifiers "91 50 52 59 53 126" '50' 'f12' '52'
assert_eq "$TUISH_EVENT" "ctrl-f12" "ctrl-f12"

# --- Non-matching input should not change TUISH_EVENT ---
TUISH_EVENT='unchanged'
_tuish_5code_modifiers "99 99 99 99 99" '49' 'up' '65'
assert_eq "$TUISH_EVENT" "unchanged" "non-matching 5code leaves TUISH_EVENT unchanged"

TUISH_EVENT='unchanged'
_tuish_6code_modifiers "99 99 99 99 99 99" '49' 'f5' '53'
assert_eq "$TUISH_EVENT" "unchanged" "non-matching 6code leaves TUISH_EVENT unchanged"

test_summary
