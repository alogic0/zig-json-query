# Pretty JSON Output and Embedded-JSON String Functions (2026-11-13)

Status: implemented, qualified and installed in 0.35.0.

This plan covers two backward-compatible ergonomics additions to `jqz` (`zig-json-query`)
observed during daily CLI and browser/API inspection workflows.

## 1. Pretty-Printed JSON Output (`-p` / `--pretty`)

### Current vs Expected

`jqz` currently emits compact single-line JSON values only:

```sh
printf '{"a":1,"b":[2,3]}\n' | jqz '.'
# {"a":1,"b":[2,3]}
```

When inspecting nested API responses or configuration objects interactively,
users currently fall back to `jq .` solely for indentation.

### Requirements

- Add `-p` / `--pretty` to the CLI (and corresponding formatting support in the
  serializer/output writer):
  - Formats emitted JSON objects and arrays with 2-space indentation and
    newlines; empty `{}` and `[]` render compactly as `{}` and `[]`.
  - Composes cleanly with `-S` (`--sort-keys`), `-r` (`--raw-output`, where
    top-level strings remain raw unquoted text while non-strings are
    pretty-printed), `-e` (`--exit-status`), `-n`, `-s`, and `--ndjson` (each
    stream result is pretty-printed and terminated by a trailing newline).
  - Support bundling `p` with no-argument short flags (`n/s/r/j/S/e/p`), EXCEPT
    define explicit, deterministic interaction with `-j` (`--join-output`):
    either reject `-p` + `-j` with a clear CLI option error (exit `2`) or
    document and test the exact behavior unambiguously (rejecting conflicting
    `-p` + `-j` with exit `2` is preferred so `--ndjson` / multi-value streams
    cannot silently concatenate multiline JSON).
- Preserve exact integer/number serialization (including `i128` / >53-bit
  integers) identically to compact output.

## 2. `fromjson` / `try_fromjson` and `tojson` Scalar Functions

### Current vs Expected

Structured logs, webhook payloads, and browser request/response captures often
embed serialized JSON inside a string field (for example `{"body":"{\"ok\":true,\"id\":42}"}`).
Querying inside `.body` currently requires piping `jqz -r '.body' | jqz '...'`.

### Requirements

- Add scalar functions in the query language (and public library evaluator):
  - `fromjson` (or `fromjson(.)`): parses a JSON string into its structured
    value within the evaluator's existing arena/memory and nesting limits;
    raises a runtime evaluation error (exit `2`) if the input is not a string or
    contains invalid JSON.
  - `try_fromjson` (or optional-compatible form): returns the parsed JSON value
    when the input is a valid JSON string, or `null` when the input is `null` or
    invalid JSON (so idioms like `.body? | try_fromjson ?? {}` compose naturally
    with `??` without aborting a multi-record `--ndjson` stream).
  - `tojson`: serializes the current value to a compact JSON string (preserving
    exact numbers and escaping).
- Enforce existing byte, depth, and allocation budgets so deeply nested or
  oversized embedded JSON strings cannot bypass `jqz` resource limits.

## Acceptance & Qualification

- Follow `AGENTS.md` strictly:
  - Use `/home/oleg/bin/zig` (`0.17.0` per `.zigversion`).
  - Implement in reviewable slices (`-p` / `--pretty` slice, then
    `fromjson`/`try_fromjson`/`tojson` slice, plus docs/plan completion).
  - Check `zig build version` and bump the minor version once for these
    backward-compatible features via `zig build version -- set <new_sem_ver>`,
    including all updated version files.
  - Commit each slice with `git commit -F <tempfile>` and remove `<tempfile>`
    using plain `rm <tempfile>` (no flags).
- Qualify both `zig build test` (Debug) and `zig build test --release=fast`,
  then build `zig build --release=fast`.
- Atomically install the qualified `ReleaseFast` binary to `/home/oleg/bin/jqz`
  (mode `0755` via a temporary file in `/home/oleg/bin`, byte-compared against
  `zig-out/bin/jqz`, then renamed into place), verify `/home/oleg/bin/jqz --version`
  and SHA-256, rerun reproducers through `/home/oleg/bin/jqz`, update `README.md`,
  `DESIGN.md` (if applicable), and this plan file with final commit SHA, version,
  and SHA-256, and remove any temporary build/test files.

## Implementation, Qualification, and Installation Record

- Delivered feature commits (following `AGENTS.md` per-feature minor version increments):
  - `075798382f3fb5fa0262b2f4b34fe6b34f0cdb9a` (`0.34.0`) — `-p` / `--pretty` CLI flag and `StreamOptions.pretty` 2-space JSON formatting (compact empty `{}` / `[]`, exact `i128` and arbitrary decimal preservation, bundling with `n/s/r/S/e/p`, composition with `--ndjson`, `-r`, `-S`, `-e`, `-n`, `-s`, and deterministic exit-`2` rejection when combined with `-j` / `join_output`).
  - `30c1bf98137c31fde79828d5c5f693e65c4d0c3f` (`0.35.0`) — `fromjson` and `try_fromjson` scalar functions (both bare current-value and unary-call forms) plus bare `tojson` alongside `tojson(expr)`, reusing `input.zig`'s validating `Scanner` / `ValueBuilder` parser in the scalar-stage arena while enforcing the 64 MiB byte cap, 128-level container nesting limit, duplicate-key rejection, and `--max-retained-bytes` collection budget.
- Qualification results (`/home/oleg/bin/zig` `0.17.0`, native `x86_64-linux`):
  - `zig build test` (Debug): **281/281** tests passed (181 library, 63 CLI, 3 file-binding, 4 package-version, 3 qualification, 18 profiler, 9 distribution-verifier).
  - `zig build test --release=fast` (`ReleaseFast`): **281/281** tests passed.
  - External public-API consumer (`tests/package`): **12/12** tests passed in both Debug and `ReleaseFast`.
- Atomic installation:
  - Final build: `zig build --release=fast` (`zig-out/bin/jqz` verified `ReleaseFast`).
  - Installed atomically via `/home/oleg/bin/.jqz.tmp.$$` (`chmod 0755`, `cmp -s` byte-verified against `zig-out/bin/jqz`, `mv` to `/home/oleg/bin/jqz`).
  - `/home/oleg/bin/jqz --version`: `jqz 0.35.0`.
  - Installed `/home/oleg/bin/jqz` SHA-256: `f3a9c20fa189fd7865f8e36ba96c3a732cc98bbbfca6337d2b079e820171114e` (identical to `zig-out/bin/jqz`).
  - CLI reproducers for `-p`, `-pj` conflict (exit `2`), and `fromjson` / `try_fromjson` / `tojson` across single-document and `--ndjson` inputs verified through `/home/oleg/bin/jqz`.
