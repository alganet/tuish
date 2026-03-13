<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Key Bindings (keybind.sh)

Declarative event-to-action mapping. Bind event names to shell
functions/commands; the default `tuish_on_event` calls `tuish_dispatch`
automatically. Source after `ord.sh`.

```sh
. ./src/ord.sh
. ./src/keybind.sh
```

## Functions

| Function                  | Description                                                              |
|---------------------------|--------------------------------------------------------------------------|
| `tuish_bind EVENT ACTION` | Bind an event name to a shell command                                    |
| `tuish_unbind EVENT`      | Remove a binding                                                         |
| `tuish_dispatch`          | Dispatch `TUISH_EVENT` through bindings (returns 0 if matched, 1 if not) |

## Matching Order

1. **Exact match** -- the full `TUISH_EVENT` string (e.g. `char x`, `ctrl-w`)
2. **Prefix glob** -- `"char *"` matches any `char X` event
3. **Catch-all** -- `"*"` matches anything not matched above

## Example

```sh
_on_quit ()  { tuish_quit_clear; }
_on_char ()  { echo "typed: ${TUISH_EVENT#char }"; }
_on_any ()   { echo "unhandled: $TUISH_EVENT"; }

tuish_bind 'ctrl-w' '_on_quit'
tuish_bind 'char *' '_on_char'
tuish_bind '*'      '_on_any'
```

The default `tuish_on_event` calls `tuish_dispatch` automatically, so no
event handler definition is needed.

## Security Note

Bound action strings are evaluated as shell code via `eval`, not just as
function names.  This means `tuish_bind 'char a' 'echo hello; ls'` will
execute both commands.  Since the caller controls both `tuish_bind` and
`tuish_dispatch`, this is safe in normal use — but avoid passing untrusted
input as the ACTION argument.

Note that `TUISH_EVENT` itself (which may contain attacker-controlled input
from paste events or mouse coordinates) is used only as a lookup key, never
passed through `eval` — only the bound action strings are evaluated.

## Internals

Bindings are stored as shell variables with sanitized event names:

| Character | Replacement |
|-----------|-------------|
| `-`       | `_D`        |
| `.`       | `_P`        |
| `*`       | `_S`        |
| space     | `_W`        |
