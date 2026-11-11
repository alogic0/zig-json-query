# Session-derived workflow qualification

The [initial implementation plan](../plans/2026-11-10-workload-qualification.md)
and [scalar-aggregate follow-up](../plans/2026-11-10-scalar-aggregates.md) track
these checkpoints. [The latest evidence](2026-11-10-scalar-aggregates.json)
records jqz 0.14.0 versus installed jq 1.7, including queries/flags,
source/fixture/binary hashes and raw measurements. The original
[0.12.0 evidence](2026-11-10.json) remains unchanged. The
[corpus notes](../../tests/qualification/README.md) explain source recovery,
sanitization and reconstruction limits.

## Reproduce

```sh
zig build test
zig build qualify -- --repeat 5 --out .zig-cache/qualification/local.json
```

Run from the repository or an extracted source package. The runner uses existing
test-support helpers, installed `/usr/bin/jq` (`jq-1.7`) and GNU time. No private
session store, network, sibling checkout or additional interpreter is needed.
This qualification uses native x86_64 Linux Debug only.

## Selected-case coverage

| Category | Result |
| --- | --- |
| Observed workflow cases | 30 |
| Equivalent translated cases | 27, up from 25 in 0.12.0 |
| Unsupported observed cases | 3 |
| Invocation adaptations included above | 1: argument-only construction needs a null input document |
| Isolated supported components | 2, outside observed-case coverage |
| Intentional semantic/exit probes | 8, all match their separate expectations |
| Generated scale cases | 2, outside observed-case coverage |
| Timed equivalent cases | 30 |
| Samples | 300: 30 cases × 2 tools × 5 repetitions |

Every reference and candidate was preflighted against frozen expectations before
timing. Unsupported jobs have checked jq results and no asserted jqz translation.
The null-input adaptation is not timed because input handling differs. This is a
deliberately chosen, unweighted sample: 27/30 is not a replacement rate for all
session invocations or general jq. Window/component adaptations are recorded per
case. Available private inputs were structurally inspected; missing backend
inputs were reconstructed from captured summaries and queries. The newly passing
grouped case is a representative projection of the larger source summary, not
qualification of every field in that original query.

Both formerly blocked embedded summaries now pass their unchanged frozen jq
expectations: grouping uses `sort_by(map(group_by(.http,.status), ...),.status)`;
totals use `sum(map(.artifact_differences,.changed_moves))`. Other outer report
fields survive both projections. Native Debug build and all 163 project tests
passed, as did five separate-package consumer tests, including exact scalar
totals, ordered groups and retained buffer ownership. This consumer check used
the checkout; the standalone archive checkpoint below remains version 0.12.0.

## Behavior differences

Checks preserve result/array ordering and exact decimal values while ignoring
object key order and numeric spelling (`1.5` equals `1.500000`). Raw output is
byte-exact. Separate probes establish false-default, missing-field, group-order,
large-integer arithmetic, duplicate-key, explicit-rounding, empty-total and
error-exit differences. jqz keeps its documented contracts in every probe.

The compiler-status translation supplies an explicit optional default. Screenshot
and fault selection spell out jq truthiness. An explicit sort matches jq's group
order for standalone and embedded grouped counts. The group-order probe now
also exercises scalar grouping, which preserves first-seen order.

The total-summary fixture is nonempty and integral. `sum([])` returns `0`, while
jq `[] | add` returns null; the new empty-total probe checks that difference.
Fractional summands and i128 overflow remain errors. Passing the selected
fixture does not assert equivalence on every input that jq accepts.

## Native Debug measurements

Target: x86_64-linux-gnu, CPU model `znver4`, Zig 0.17.0. jqz is Debug; installed
jq build flags are unknown. GNU time reports version `UNKNOWN`, so its SHA-256
is recorded alongside both query tools. Each median has five repetitions. RSS
was available for all 300 samples.

| Case | jqz median ms | jq median ms | jqz median RSS MiB | jq median RSS MiB |
| --- | ---: | ---: | ---: | ---: |
| Report summary, 990 bytes | 9.502 | 4.063 | 5.953 | 3.473 |
| Compiler-call count, 523 bytes | 12.706 | 4.150 | 6.180 | 3.555 |
| Timing mean, 65 bytes | 9.559 | 4.295 | 5.934 | 3.527 |
| Embedded grouped summary, 990 bytes | 9.560 | 4.225 | 6.063 | 3.527 |
| Embedded total summary, 430 bytes | 9.648 | 4.133 | 5.953 | 3.445 |
| 2,837 generated commands, 507,825 bytes | 54.443 | 14.855 | 13.297 | 8.164 |
| 10,000 HTTP + 10,000 fixtures, 860,080 bytes | 99.216 | 25.479 | 18.203 | 18.523 |

For the last two cases, jqz wall-time ranges were 53.422–56.234 ms and
98.000–104.268 ms; jq ranges were 13.578–15.914 ms and 24.494–27.151 ms.
All 30 timed cases had higher jqz median wall time. The larger report had
comparable peak RSS. Small cases are strongly affected by startup and process
supervision/capture. Scale fixtures preserve shapes/cardinalities, not original
payload bytes/distributions. Five repetitions, warm caches, Debug versus an
installed distribution binary, and these selected jobs do not establish general
performance advantages. This run does not isolate parsing/allocation costs.
Differences from the historical 0.12.0 run do not establish an engine speedup.

## Priorities supported by this sample

The first follow-up, scalar report grouping/totals, is complete in 0.14.0.
Remaining priorities are:

1. JSON serialization with explicit byte/character sizing, for
   `serialized-sample-size`; its ASCII fixture does not settle Unicode sizing.
2. Targeted deletion preserving arbitrary fields and sorted-key output, for
   `normalize-config`.
3. Structural-array ordering/distinctness, for `distinct-schema-shapes`.
4. Profile Debug startup and parsing/allocation on representative larger payloads
   before choosing engine optimizations or incremental parsing work.

Constant suffix matching and scalar schema-key unions already translate through
regex and grouping/sorting. Helpers could shorten those queries, while the three
remaining unsupported workflows require additional capabilities.

## Historical standalone source and consumer (0.12.0)

[package-evidence.json](package-evidence.json) records the qualified 368,248-byte
source snapshot, archive/compiler/binary hashes, normalized commands and results.
Its archive SHA-256 is
`0412226d66bb709c641fc3e019b9b843eb005a0759785dcc882d2831766e0a08`;
an unchanged rebuild produced identical bytes. Caches/build outputs were excluded.
The archive was produced before its result documents, so it is a qualification
snapshot; later changes are test-readme/qualification documentation. All code,
consumer main and corpus fingerprints match the recorded code checkpoint.

A fresh extraction outside the checkout passed 147/147 tests, built jqz 0.12.0,
and replayed all 41 corpus checks (56 one-repetition smoke samples). Source/corpus
hashes match the measured checkout. All three bundled dependency checksums pass.
A sibling independent consumer, copied from the archive with only its dependency
path adjusted, passed 4/4 tests using its own empty caches. These exercise buffer
ownership, named feeds, slurp retention, quantifiers, decimal statistics and
predicate status through the public API. Each Debug executable hash is recorded
separately; build paths can affect binary bytes.

To reproduce, extract a freshly built archive into a temporary `source` directory,
copy `tests/package` into a sibling `consumer`, and change only its `json_query`
dependency path from `../..` to `../source`. Initialize those temporary projects
independently if using Git. Use fresh local/global caches per project and an
initially absent local package directory:

```sh
# From the extracted source; SOURCE_GLOBAL/SOURCE_LOCAL are fresh absolute paths.
ZIG_GLOBAL_CACHE_DIR="$SOURCE_GLOBAL" ZIG_LOCAL_PKG_DIR=zig-pkg \
  zig build test --summary all --cache-dir "$SOURCE_LOCAL"
ZIG_GLOBAL_CACHE_DIR="$SOURCE_GLOBAL" ZIG_LOCAL_PKG_DIR=zig-pkg \
  zig build --cache-dir "$SOURCE_LOCAL"
ZIG_GLOBAL_CACHE_DIR="$SOURCE_GLOBAL" ZIG_LOCAL_PKG_DIR=zig-pkg \
  zig build qualify --cache-dir "$SOURCE_LOCAL" -- --repeat 1 --out replay.json

# From the separate consumer, with a different fresh cache pair.
ZIG_GLOBAL_CACHE_DIR="$CONSUMER_GLOBAL" ZIG_LOCAL_PKG_DIR=zig-pkg \
  zig build test --summary all --cache-dir "$CONSUMER_LOCAL"
```

This Zig 0.17.0 installation rejects `zig build --global-cache-dir`; the global
cache is selected through the environment. Its package-cache override must stay
relative. Native Debug is the only build mode used for this qualification.
