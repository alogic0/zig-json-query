# Compiler-report queries

These examples translate observed `z_llvm` session queries, initially audited on
jqz 0.28.0. Joined path output is available starting in 0.29.0. The
[audit plan](../../docs/plans/2026-11-11-zllvm-translation.md) and translation
manifest at `docs/experiments/zllvm_translations.json` record the reference jq
filters. Actual retained compiler inputs were checked with independent jq
results; synthetic checks cover missing/null fields, ties, empty streams and
negative predicate status. These examples add no query-language features.
The jq reference uses `-c` to match jqz's compact JSON default.

Run from the jqz checkout, after `zig build`:

```sh
./zig-out/bin/jqz -f examples/zllvm/command-progress.query \
  ../z_llvm/local-state/validations/validation-performance-20261109/c-debug/commands.json

./zig-out/bin/jqz --ndjson -f examples/zllvm/census-counts.query \
  ../z_llvm/local-state/validations/compiler-selection-completion-20261108/batch-30/census-whole-v3.jsonl
```

| Query | Behavior |
| --- | --- |
| `command-progress.query` | Command count and last argv |
| `command-count-and-tail.query` | Two results: count, then last argv/return code |
| `recent-commands.query` | The original last-four-command window |
| `compiler-call-count.query` | Count argv programs ending in `/z_llvm` |
| `census-counts.query` | Examined and failed function counts, preserving jq truthiness |
| `census-progress.query` | Completed function count and latest function name |
| `grouped-rejections.query` | Rejection counts and two examples per boundary |
| `grouped-selector-pairs.query` | Rejection groups by selector tag and detail |
| `nul-paths.query` | NUL-delimited paths; run with `-j` (0.29.0+) |
| `compare-source-files.query` | Compare single-document `.files` manifests through `--slurpfile before/after` (0.30.0+) |

Use ordinary JSON mode for command-array files and `--ndjson` for census/event
logs. Census/grouping translations consume records directly: omit jq's `-s`.
They project small values before retention and use existing completion stages;
the shared 64 MiB retention budget still applies. Grouped examples explicitly
sort group keys before the stable count sort to preserve jq's tie order. Nullable
metadata uses `? ?? null` because jqz shorthand is strict about missing fields.

`provenance-duration.query` is a reviewed alternative with a numeric difference:
it emits exact nanosecond-precision decimal seconds. The original jq floating
calculation loses precision while subtracting epoch nanosecond timestamps beyond
`2^53`, producing different decimals on the checked reports. Accept
that contract explicitly before adopting this example as a report replacement.

The 0.28.0 audit preserves the historical NUL path counterexample. Starting with
0.29.0, use `jqz -j -f examples/zllvm/nul-paths.query FILE` to emit each path plus
NUL with no added newlines. The
[three live path checks](../../docs/qualification/2026-11-11-join-output.json)
match jq byte-for-byte. The
[CLI follow-up plan](../../docs/plans/2026-11-11-cli-output-and-file-bindings.md)
records its fresh live checks and file-binding work.

For two source manifests, each containing one object with a `.files` map:

```sh
./zig-out/bin/jqz -n --slurpfile before old-source.json --slurpfile after new-source.json \
  -f examples/zllvm/compare-source-files.query
```

Use `--rawfile NAME FILE` to bind a retained UTF-8 text log; `jqz -nj --rawfile
text LOG '$text'` writes its exact bytes. These file-binding components do not
add local `as`/`def`/`reduce` syntax or dynamic indexes needed by larger scripts.
The [0.30.0 live evidence](../../docs/qualification/2026-11-11-file-bindings.json)
rechecks all three NUL-path invocations and both file-binding components with
exact output bytes and stable retained inputs.
