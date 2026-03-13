<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Shell Compatibility

## Supported Shells

| Shell      | Version  | Read Method    |
|------------|----------|----------------|
| bash       | 4+       | `read -n 1`    |
| zsh        | 5+       | `read -k1 -u0` |
| ksh93      | AJM 93u+ | `read -n 1`    |
| mksh       | R59+     | `read -n 1`    |
| busybox sh | 1.30+    | `read -n 1`    |

tui.sh auto-detects the read method at startup.

## Locale

compat.sh sets `LC_ALL=C` and `LC_CTYPE=C` at source time for consistent byte handling across all shells. Before overwriting these variables, it saves the original values in `_tuish_orig_lang`, `_tuish_orig_lc_all`, and `_tuish_orig_lc_ctype`. This allows modules like draw.sh to check the saved locale and detect UTF-8 support even after the C locale is active.

## Module Sourcing Order

`compat.sh` must be sourced first (shell normalization), then `ord.sh` (ASCII tables), then `tui.sh`. Other modules can be sourced in any order after that, with the following exceptions:

- `hid.sh` requires `event.sh`
- `viewport.sh` requires `term.sh` and `event.sh`
- `draw.sh` requires `term.sh` and `str.sh`

## Timeout Resolution

| Resolution               | Shells                 | Idle Timeout                                  |
|--------------------------|------------------------|-----------------------------------------------|
| `sub` (subsecond)        | bash, zsh, ksh93, mksh | 0.26s (configurable via `TUISH_IDLE_TIMEOUT`) |
| `second` (whole seconds) | busybox sh             | 1s minimum                                    |

Check `TUISH_TIMING` after `tuish_init` to know which is active.

## Shell-Specific Notes

### bash
Full support. No known limitations.

### zsh
Full support with minor caveats:
- `setopt` options (`FLOW_CONTROL`, `GLOB`, etc.) are automatically
  disabled by tui.sh
- Bare ESC detection is unreliable under zsh+tmux due to terminal
  driver buffering. Works in direct terminal usage.
- Alt+Ctrl+letter delivery is unreliable under zsh+tmux.

### ksh93
Full support. `local` is aliased to `typeset` for POSIX-style functions.

### mksh (MIRBSD KSH)
Full support. `local` is aliased to `typeset`. Uses `echo -ne` instead
of `printf` for output (mksh has no builtin `printf`). Unicode
box-drawing characters use `\xHH` hex escapes which work with both
`printf` and `echo -ne`.

### busybox sh
Works with limitations:
- Only whole-second timeouts (`TUISH_TIMING='second'`)
- String utilities (`tuish_str_*`) may not be available (requires
  `${var:off:len}` support, which varies by busybox build)

## String Utilities

The `tuish_str_*` functions use `${var:off:len}` parameter expansion,
which is supported by bash, zsh, ksh93, and mksh but is not part of the
POSIX standard. Availability on busybox sh depends on the build
configuration.

## Known Terminal Limitations

- **CR (Enter) via tmux PTY**: The terminal driver may translate CR
  before it reaches the raw-mode read. Works in direct terminal usage.
- **Shift+Ctrl+letter (VT protocol)**: Indistinguishable from
  Ctrl+letter. Use the kitty keyboard protocol for disambiguation.
- **DECAWM (auto-wrap)**: Disabled by default (`tuish_wrap_off`).
  Universally supported by xterm, VTE, kitty, alacritty, Windows
  Terminal, iTerm2, mintty, tmux, and screen.

## Keyboard Protocol

The keyboard protocol defaults to VT.  Call `tuish_kitty_on` after
`tuish_init` to probe the terminal and enable the kitty keyboard
protocol if supported.  `tuish_kitty_off` (and `tuish_fini`) restore
VT mode.
