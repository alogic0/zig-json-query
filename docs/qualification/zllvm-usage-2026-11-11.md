# Real z_llvm jq usage translated to jqz 0.28.0

Common compiler-inspection jobs work with jqz: 56 live comparisons across 25
query forms produce identical compact/raw bytes and exit statuses. Six further
comparisons demonstrate two reviewed differences: joined raw output and floating
duration arithmetic. Larger acceptance/comparison scripts also use file bindings
and language constructs that need additional implementation or a Zig workflow.

The [plan](../plans/2026-11-11-zllvm-translation.md) is complete. The
[translation manifest](../experiments/zllvm_translations.json),
[reusable examples](../../examples/zllvm/README.md) and
[Zig experiment](../experiments/zllvm_usage.zig) were implemented at
`5cc4fbe5fb848ee4e17936673e3b5025ff265dc7`, with timestamp-precision regression
`27cbc34` clarifying the numeric difference. jqz runtime/version behavior stays at
0.28.0. The compiler checkout and original history were read only.

## Scope and inventory

The source is compiler session `01a1c2a9-b739-7e13-b134-3167995ee5d1` in
`~/.codex-llc/sessions/2026/11/09/`, plus current `/home/oleg/prog/z_llvm` files.
The fixed history snapshot hash is
`54ff8b1ba32f9de4ee62eee025eddf8f0e51ecce3b29a57d76fed0c40fe820c1`.
Candidate extraction is reproducible through physical JSONL record 37,583.

The [query-only inventory](2026-11-11-zllvm-inventory.json) records:

| Observation | Count |
| --- | ---: |
| Distinct completed-command records mentioning jq/jg | 1,968 |
| Candidate records under the compiler checkout/worktrees | 1,967 |
| Recognized command-position invocations | 2,711 jq, zero jg |
| Distinct literal inline filter texts | 1,225 |
| Invocations with dynamic arguments/context | 305 |
| Query-file invocations | 90, with 22 distinct argument strings |
| `--slurpfile` / `--rawfile` invocations | 215 / 11 |
| Current retained `.jq` files | 176 |

This is a conservative lexical inventory, with quoting, escapes, command
positions and heredoc skipping. It never evaluates shell expansions or executes
history. Wrappers, backticks, query interpolation and upstream stdin pipelines
need separate interpretation. Candidate records can contain searches/query
definitions; they are not an invocation count. Repeated uses are not independent
feature coverage, and a literal filter can still have dynamic data arguments.

The tracked compiler scripts/tools have almost no active jq call sites. The
176 query files primarily live in retained validation directories. Textual cues
include local `as` bindings in 113 files, `def` in 108, `from_entries` in 61,
`capture` in 39 and `tonumber` in 43. These are review cues, not parsed capability
counts. Rewriting those retained artifacts would change historical evidence.

## Live checks and useful translations

The [machine-readable checks](2026-11-11-zllvm-translations.json) cover 27 of
30 mapped filters, using up to three distinct retained input sets per filter.
The mapped texts occur at 1,148 recognized history sites; this does not mean
that every site/input was replayed. Results are 56 equivalent pairs and six
expected differences. All 56 equivalent pairs are byte-identical; exact-decimal
JSON comparison is also available and preserves result/array order.
The reference uses `jq -c` to match jqz's compact default; raw-output checks
compare the original byte framing.

| Job | Translation / result |
| --- | --- |
| Process status, outcomes, return codes and durations in nanoseconds | Explicit nullable fields preserve jq's missing-to-null projection behavior |
| Command progress and compiler-call counts | `length(.)`, indexed argv and an anchored suffix regex |
| Original last-four command window | `map(.[-4:], {...})`, keeping the full original window |
| Count followed by last-command object | `[length(.), {...}] | each` produces both results in order |
| Terminal event filtering | `where((.event? ?? null) == "complete")` with `--ndjson` |
| Census totals and progress | Project values before grouping/collection; finish the existing stream once |
| Grouped selector/rejection summaries | Structural key ordering before stable count sorting preserves jq's ties, null keys and original function order |
| Predicate gates | Same successful live exits; a sanitized negative gate also checks exit 1 with `-e` |

The three filters without resolvable original inputs are `event-sequence`,
`event-function` and `provenance-status`. Their manifest translations remain
unverified against those original pipelines/files. They are excluded from the
25 verified equivalent forms.

The runner launches only explicit jq/jqz argv, with 10-second deadlines,
8 MiB capture bounds and 32 MiB per-input-file limits. It checks input hashes
before/after each pair and tool identities across the audit. Unavailable,
dynamic, unsupported-flag and oversized inputs are counted separately. Output
payloads/binding values are not published; evidence retains sizes/hashes, input
identities and flags. This is functional qualification, with no speed claim.

Eight fresh native Debug audit tests cover lexical safety, exact-number/result
comparison and sanitized oracle fixtures. They include missing/null/zero/string
truthiness, empty completion, multiple results, exit 1, equal-count group ties,
null group keys, the NUL protocol difference and timestamp precision beyond
`2^53`. `zig build` and `zig build test`
also pass, reusing unchanged cached project results. The original 45-case corpus
and earlier qualification/package checkpoints are unchanged.

## Differences and migration priorities

1. **Joined raw output.** The observed `.files|keys[]|.,"\u0000"` with `jq -jr`
   is a NUL-delimited path protocol. jqz can construct the values, but `-r` adds
   newlines after each result and `-j`/`--join-output` is absent. Three actual
   file-manifest checks and a sanitized byte-level counterexample confirm the
   mismatch. Adding a correctly tested join-output option is the smallest
   concrete next CLI improvement.
2. **File bindings.** `--slurpfile` and `--rawfile` are used heavily in multi-report
   acceptance/comparison work. Existing `--argjson`/`--arg` bind supplied values;
   they do not read these files. A proper file-binding design would preserve
   validation, ownership, limits and failure ordering without shell expansion.
3. **Local bindings and dynamic maps.** Retained scripts use `as`, `def`,
   `reduce`, `from_entries` and lookups such as `$baseline[.function]`. Some short
   uses can be inlined, but the larger comparison programs need a considered
   language design or equivalent maintained Zig tooling. The profile comparison
   script also uses recursive object filtering, and classification scripts use
   regex captures and numeric string conversion.
4. **Duration arithmetic.** `provenance-duration.query` computes exact decimal
   seconds with `divide(...,1000000000,9)`. Three real input sets differ from
   jq's floating-point decimals, despite matching zero exits. The reports use
   epoch nanosecond timestamps beyond `2^53`: floating subtraction already loses
   precision before division, while jqz subtracts exact integers. A sanitized
   adjacent-timestamp regression isolates this loss. The comparison
   intentionally uses exact decimal equality. This alternative requires an
   explicit numeric-contract decision before adoption; it is not counted as
   an equivalent replacement.

These observations extend the earlier selected workload study. They establish
useful current replacements and concrete next requirements, rather than general
jq compatibility or complete migration of all 176 scripts.

## Reproduction and integrity

Run from the jqz checkout. Existing Zig/jq and pinned test-support suffice:

```sh
set -e
set -o pipefail
zig build
mkdir -p zig-out/zllvm-translation
jqz_support=zig-pkg/test_support-0.2.0-WfGxyjo5BAB0686gSkz5ucgtYJWyK1q9Idd0xXji0hue
zig build-exe --dep test_support --dep exact_number \
  -Mroot=docs/experiments/zllvm_usage.zig --dep process \
  -Mtest_support="$jqz_support/src/root.zig" \
  -Mprocess="$jqz_support/vendor/zig-process/src/root.zig" \
  -Mexact_number=src/number.zig -femit-bin=zig-out/zllvm-translation/audit
```

The same compiler module arguments work with `zig test` for the eight fixture
checks. Generate an ignored metadata-only command extract with installed jq:

```sh
jq -nc 'limit(37583;inputs)
  | select(.type=="event_msg" and .payload.type=="item_completed"
      and .payload.item.type=="CommandExecution")
  | .payload.item as $item
  | select(($item.command|type)=="array" and ($item.command[-1]|type)=="string")
  | select($item.command[-1]|test("(^|[^A-Za-z0-9_])(jq|jg)([^A-Za-z0-9_]|$)"))
  | {record:input_line_number,id:$item.id,cwd:$item.cwd,
     command:$item.command[-1],exit_code:$item.exit_code}' \
  ~/.codex-llc/sessions/2026/11/09/rollout-2026-11-09T17-34-24-01a1c2a9-b739-7e13-b134-3167995ee5d1.jsonl \
  | jq -s 'unique_by(.id)|sort_by(.record)' \
  > zig-out/zllvm-translation/commands.private.json

zig-out/zllvm-translation/audit inventory \
  zig-out/zllvm-translation/commands.private.json \
  zig-out/zllvm-translation/invocations.private.json
zig-out/zllvm-translation/audit catalog \
  zig-out/zllvm-translation/invocations.private.json ~/prog/z_llvm \
  zig-out/zllvm-translation/catalog.json
zig-out/zllvm-translation/audit compare \
  zig-out/zllvm-translation/invocations.private.json \
  docs/experiments/zllvm_translations.json zig-out/bin/jqz \
  zig-out/zllvm-translation/checks.json
rm zig-out/zllvm-translation/commands.private.json
rm zig-out/zllvm-translation/invocations.private.json
```

The fixed-boundary extraction was independently repeated and compared before
cleanup. Retained inputs/current scripts can change later; unavailable data is
reported explicitly. The original raw snapshot and private command/invocation
extracts are removed with plain `rm`. The published JSON files are unchanged
copies of the generated results:

| Artifact | SHA-256 |
| --- | --- |
| Query inventory | `320e9d6648b7b5b557e62edfdcc476e5b2cb44e0dee37439f64c7e73f488717c` |
| Live translation checks | `8d43471303e691449b565d0af000bfc0b6e095a7d43f4f22df1a405ecff90e51` |

The live report also pins the experiment source, translation manifest and both
binaries. Source/script inspection, query translations and all validation helpers
are Zig or existing command-line tools; no additional interpreter or compiler
target was introduced.
