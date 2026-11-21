# Manifest comparison

These fixtures are JSON arrays of `{path,sha256,size}` records. They include a
hash-only change, a size-only change above 2^53, and added/removed paths. Run from
the project root after `zig build`:

```sh
./zig-out/bin/jqz -n --slurpfile before examples/cleanup/before.json \
  --slurpfile after examples/cleanup/after.json -f examples/cleanup/left-match.query
./zig-out/bin/jqz -n --slurpfile before examples/cleanup/before.json \
  --slurpfile after examples/cleanup/after.json -f examples/cleanup/inner-match.query
./zig-out/bin/jqz -n --slurpfile before examples/cleanup/before.json \
  --slurpfile after examples/cleanup/after.json -f examples/cleanup/changes.query
./zig-out/bin/jqz -nr --slurpfile before examples/cleanup/before.json \
  --slurpfile after examples/cleanup/after.json -f examples/cleanup/removed.query
./zig-out/bin/jqz -nr --slurpfile before examples/cleanup/before.json \
  --slurpfile after examples/cleanup/after.json -f examples/cleanup/added.query
```

`index_by(.path)` constructs the right index once, rejecting duplicate paths.
`root()` makes that stage input available inside `map`, while `.` refers to the
current left record. `exists(root()[.path]?)` tests membership without confusing
missing keys with present null/false values. The examples' indexed records are
objects; the general lookup API also preserves null/false values. Left matching
emits every left record; inner matching keeps the matched records. Both preserve
left order. The change report lists `b` then `a`, removed emits `removed`, and
the reversed comparison emits `added` in after-input order.

Empty right input still creates `{}`, so every left record remains available as
an unmatched record. Index storage owns its records and shares
`--max-retained-bytes` with other retaining stages. File binding text remains
subject to its separate admission limits. `map` constructs its result in scalar
temporary storage; that capacity is separate from index retention and is not an
RSS bound. Increase the retained budget explicitly for a larger index.

For NDJSON totals over `{category,size}` records, use
`jqz --ndjson -f examples/cleanup-totals.query records.jsonl`. It keeps distinct
category keys and checked count/sum accumulators under the retained budget.

For an ordered command receipt, the cases supply names and expected exit codes.
The commands supply their working directories, argv, observed codes and log
paths. The query constructs each expected path with `concat` and compares the
arrays in their recorded order. This invocation prints `true` and exits 0.

```sh
./zig-out/bin/jqz -e --arg stage /run --slurpfile cases examples/cleanup/cases.json \
  -f examples/cleanup/verify-commands.query examples/cleanup/commands.json
```
