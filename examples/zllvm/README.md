# Compiler-report queries

These jqz 0.28.0 examples translate observed `z_llvm` session queries. The
[audit plan](../../docs/plans/2026-11-11-zllvm-translation.md) and translation
manifest at `docs/experiments/zllvm_translations.json` record the reference jq
filters. Actual retained compiler inputs were checked with independent jq
results; synthetic checks cover missing/null fields, ties, empty streams and
negative predicate status. These examples add no query-language features.

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

Use ordinary JSON mode for command-array files and `--ndjson` for census/event
logs. Census/grouping translations consume records directly: omit jq's `-s`.
They project small values before retention and use existing completion stages;
the shared 64 MiB retention budget still applies. Grouped examples explicitly
sort group keys before the stable count sort to preserve jq's tie order. Nullable
metadata uses `? ?? null` because jqz shorthand is strict about missing fields.

`provenance-duration.query` is a reviewed alternative with a numeric difference:
it emits exact nanosecond-precision decimal seconds. The original jq floating
calculation produces different decimals on the checked real reports. Accept
that contract explicitly before adopting this example as a report replacement.

The observed NUL-delimited path protocol (`jq -jr`) also differs: jqz raw output
adds a newline to every result and currently has no `-j` / `--join-output` option.
The audit keeps this counterexample outside the equivalent examples above.
