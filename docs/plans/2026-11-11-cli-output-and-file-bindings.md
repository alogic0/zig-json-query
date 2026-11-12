# Joined output and file bindings

Status: joined output verified as 0.29.0 and file bindings verified as 0.30.0;
final corpus and live component qualification remain in progress.

## Objective

Close the concrete CLI requirements from the
[real compiler audit](../qualification/zllvm-usage-2026-11-11.md): first joined
raw output, then the `--slurpfile` / `--rawfile` follow-up. Use Zig and existing
pinned dependencies/tools. Keep compiler sources, retained inputs and historical
qualification evidence unchanged. Validate native x86_64 Linux Debug only.

## Contracts

- `-j` / `--join-output` implies raw strings and suppresses the trailing newline
  for every emitted value, including non-strings. Preserve embedded bytes,
  JSON serialization/sorted keys, flushing, early stop, completion, error
  precedence and value-based `-e` status. Empty strings are emitted values even
  when they write zero bytes. Stream options expose the same default-off mode.
- Accept ordinary no-argument short-option bundles using `n`, `s`, `r`, `j`,
  `S`, `e` (including observed `-jr`/`-rj`). Argument-taking options remain
  separate. Unknown options still fail; `--` still terminates option parsing.
- `--slurpfile NAME FILE` binds an array of all JSON values in the named file,
  including empty, NDJSON and multiline/adjacent container documents. Reuse
  Zig's validating Scanner for boundaries; keep original number spellings and
  validate duplicate keys, UTF-8 and depth through normal binding compilation.
- `--rawfile NAME FILE` binds exact UTF-8 text, including newlines, empty text
  and NUL. Invalid UTF-8 remains a binding error. File arguments are literal
  named paths: `-` is a filename, not stdin. Query/stdin/data modes stay distinct.
- Read/validate file bindings even when unused, under `-n` or before `take(0)`.
  Share the existing 128-name limit and duplicate/name checks across all binding
  kinds. Bound source text and prepared binding text each share a 64 MiB total
  cap; encoded slurp arrays count toward nesting/text admission. Query files
  are resolved first as today; binding failures precede primary input reads.
  Every file and owned buffer is released on success/failure.

## Verified slices

1. [x] Record/commit this plan after checking CLI, writer, binding and Scanner
   APIs and installed jq behavior. Link it from the README.
2. [x] Implement joined output and no-argument short bundles. Add meaningful
   CLI/library checks for NUL/Unicode/empty strings, JSON/non-string results,
   status, query files, streaming completion and failed writes. Add a separate
   consumer check. Read `zig build version`, set minor 0.29.0 through the pinned
   tool, include all marker files, run native build/tests/consumer, then commit.
3. [x] Recheck the three real path manifests with explicit jq/jqz argv and the
   joined-output flag. Require identical output bytes, exit statuses and stable
   input/tool identities. Preserve a new versioned evidence file and ready query;
   keep the 0.28.0 counterexample unchanged. Commit this verified evidence slice.
4. [x] Implement file bindings with bounded reads, JSON-sequence framing and
   owned prepared values. Test multiline/empty/adjacent values, exact numbers,
   escaped keys/duplicates, invalid/truncated input, UTF-8/NUL, limits, depth,
   duplicate names, unused bindings, query/stdin composition and failure cleanup.
   Read/set minor 0.30.0 with the pinned version tool, run focused/full native
   checks, document contracts/examples, and commit before final qualification.
5. [ ] Run the unchanged 45-case corpus and focused live CLI checks. Recheck
   joined path framing after CLI changes; compare multi-file JSON bindings and
   raw-file bytes on retained compiler data as separate component scenarios,
   without inflating observed coverage. Preserve new evidence, verify hashes,
   mark this plan complete and commit the report slice.

Write complete commit messages into temporary files, use `git commit -F`, and
remove those files after success with plain `rm`. Each verified slice precedes
the next. Keep major 0 unchanged; no architecture/build-mode matrix, publication,
new interpreter or additional query-language feature is included.

## Verification record

Joined-output slice: native Debug build and all 240 project checks pass (160
library, 47 CLI, four version, three qualification, eighteen profiler and eight
distribution-verifier checks). The separate public consumer passes nine checks.
New coverage includes exact NUL/Unicode/JSON bytes, zero-byte string status,
bundled flags and `--`, query files, multiple inputs, completion/early stop,
library writer failures and CLI `/dev/full` failure precedence. Version markers,
formatting and diff checks pass at 0.29.0.

The [live joined-output checks](../qualification/2026-11-11-join-output.json)
pass for all three original compiler path manifests: 171,036 / 171,424 / 171,708
output bytes match jq exactly with zero exits and stable input hashes. The
[qualification note](../qualification/cli-output-and-bindings-2026-11-11.md)
records the independent helper and result boundary. Original audit evidence is
unchanged. The feature and live proof are committed before file-binding code.

File-binding slice: native Debug build and the full project suite pass at
0.30.0, with 249 checks (160 library, 53 CLI, three binding-input, four version,
three qualification, eighteen profiler and eight distribution-verifier checks).
New checks cover exact JSON/raw/NUL bytes, empty/multiline/adjacent documents,
decoded duplicate keys, invalid/truncated/UTF-8 input, shared admission, wrapper
depth, name limits, literal dash paths, unused bindings and query/stdin/early-stop
composition. Framing passes allocation-failure injection, and a bounded
non-positional read rejects `/dev/zero`. Prepared buffers are released after
compilation owns copies; no library file-IO interface was added. The pinned
version tool synchronized every 0.30.0 marker; formatting and diff checks pass.
