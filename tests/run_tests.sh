#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Test runner for tui.sh — runs unit tests across available shells

set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
_total_pass=0
_total_fail=0
_total_suites=0

run_test () {
	local shell="$1"
	local test_file="$2"
	local test_type="$3"

	if test "$test_type" = "unit"
	then
		result=$($shell "$test_file" 2>&1) || :
	else
		result=$(TUISH_SHELL="$shell" bash "$test_file" 2>&1) || :
	fi

	printf '%s\n' "$result"

	# Extract pass/fail counts from summary line
	summary=$(printf '%s' "$result" | grep 'passed,' | tail -1)
	if test -n "$summary"
	then
		passed=$(printf '%s' "$summary" | sed 's/.*] \([0-9]*\)\/.*/\1/')
		total=$(printf '%s' "$summary" | sed 's|.*/\([0-9]*\) passed.*|\1|')
		failed=$(printf '%s' "$summary" | sed 's/.* \([0-9]*\) failed/\1/')
		_total_pass=$((_total_pass + passed))
		_total_fail=$((_total_fail + failed))
	fi
	_total_suites=$((_total_suites + 1))
}

# Check if a shell supports tui.sh interactive mode (read -n or read -k)
# Note: $1 is intentionally unquoted to allow multi-word commands like "busybox sh"
can_run_interactive () {
	$1 -c '{ echo 1 | read -s -k1 2>/dev/null ;} || { echo 1 | read -r -t 0.1 -n 1 2>/dev/null ;}' 2>/dev/null
}

run_shell_tests () {
	local shell="$1"
	local label="$2"

	printf '========================================\n'
	printf '  Shell: %s\n' "$label"
	printf '========================================\n\n'

	# Unit tests — run in the target shell
	for test_file in "$TESTS_DIR"/unit/test_*.sh
	do
		run_test "$shell" "$test_file" "unit"
		printf '\n'
	done
}

if test $# -gt 0
then
	# Run a single shell specified as argument
	run_shell_tests "$1" "$1"
else
	for shell in bash zsh ksh mksh
	do
		if ! command -v "$shell" >/dev/null 2>&1
		then
			printf 'SKIP: %s not found\n\n' "$shell"
			continue
		fi
		run_shell_tests "$shell" "$shell"
	done

	# busybox sh — separate because the command is two words
	if command -v busybox >/dev/null 2>&1
	then
		run_shell_tests "busybox sh" "busybox sh"
	fi
fi

printf '========================================\n'
printf '  TOTAL: %d passed, %d failed (%d suites)\n' "$_total_pass" "$_total_fail" "$_total_suites"
printf '========================================\n'

test "$_total_fail" -eq 0
