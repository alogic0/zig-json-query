# Session-derived workflow qualification

The [initial implementation plan](../plans/2026-11-10-workload-qualification.md),
[scalar-aggregate follow-up](../plans/2026-11-10-scalar-aggregates.md) and
[remaining-workflow plan](../plans/2026-11-10-remaining-workflows.md) track these
checkpoints. [The latest evidence](2026-11-11-remaining-workflows.json) records
jqz 0.18.1 versus installed jq 1.7, including queries/flags, source/fixture/binary
hashes and raw measurements. The historical [0.14.0 evidence](2026-11-10-scalar-aggregates.json)
and [0.12.0 evidence](2026-11-10.json) remain unchanged. The
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
| Equivalent translated cases | 30, up from 27 in 0.14.0 and 25 in 0.12.0 |
| Unsupported observed cases | 0 |
| Invocation adaptations included above | 1: argument-only construction needs a null input document |
| Isolated supported components | 3, outside observed-case coverage |
| Intentional semantic/exit probes | 10, all match their separate expectations |
| Generated scale cases | 2, outside observed-case coverage |
| Timed equivalent cases | 34 |
| Samples | 340: 34 cases × 2 tools × 5 repetitions |

Every reference and candidate was preflighted against frozen expectations before
timing. The null-input adaptation is not timed because input handling differs.
This is a deliberately chosen, unweighted sample: 30/30 is not a replacement rate for all
session invocations or general jq. Window/component adaptations are recorded per
case. Available private inputs were structurally inspected; missing backend
inputs were reconstructed from captured summaries and queries. The grouped case
is a representative projection of the larger source summary, not
qualification of every field in that original query.

The three remaining gaps now pass their unchanged frozen jq expectations:
`serialized-sample-size` uses `byte_length(tojson(.samples[0]))`,
`normalize-config` uses an immutable `update` with array filtering and `-S`, and
`distinct-schema-shapes` uses `unique(map(.fixtures,keys(.)))`. The additional
sorted-output component checks compact bytes, including nested object-key order.
The earlier embedded grouping/totals translations still pass.

Native Debug build/tests pass: 195 project checks (145 language/library, 37 CLI,
four version-workflow, three qualification-runner and six profiler/meter), plus
eight separate-package consumer tests. Changed checks ran before their commits;
the final invocation reused valid cached checks and ran the final consumer tests.
These checks include retention ownership, Unicode sizing, immutable edits and
structural sets. The consumer uses the checkout; the standalone archive checkpoint
below remains version 0.12.0.

## Behavior differences

Checks preserve result/array ordering and exact decimal values while ignoring
object key order and numeric spelling (`1.5` equals `1.500000`). Raw output is
byte-exact. Separate probes establish false-default, missing-field, group-order,
large-integer arithmetic, duplicate-key, explicit-rounding, empty-total and
error-exit differences, plus explicit UTF-8 byte sizing and strict missing-path
deletion. jqz keeps its documented contracts in every probe.

The compiler-status translation supplies an explicit optional default. Screenshot
and fault selection spell out jq truthiness. An explicit sort matches jq's group
order for standalone and embedded grouped counts. The group-order probe now
also exercises scalar grouping, which preserves first-seen order.

The total-summary fixture is nonempty and integral. `sum([])` returns `0`, while
jq `[] | add` returns null; the new empty-total probe checks that difference.
Fractional summands and i128 overflow remain errors. Passing the selected
fixture does not assert equivalence on every input that jq accepts.

The observed serialization fixture is ASCII: jq's scalar count and jqz's byte
count both produce 47. The Unicode probe separately establishes 4 scalar values
versus 8 bytes for the JSON text of `"é😀"`. Missing deletion is an error in jqz,
whereas jq ignores the absent field. Sorted-key output is compact and preserves
number spelling; its exact-byte check uses jq `-c -S` for the same format.

## Native Debug measurements

Target: x86_64-linux-gnu, CPU model `znver4`, Zig 0.17.0. jqz is Debug; installed
jq build flags are unknown. GNU time reports version `UNKNOWN`, so its SHA-256
is recorded alongside both query tools. Each median has five repetitions. RSS
was available for all 340 samples.

| Case | jqz median ms | jq median ms | jqz median RSS MiB | jq median RSS MiB |
| --- | ---: | ---: | ---: | ---: |
| Report summary, 990 bytes | 10.661 | 4.192 | 6.172 | 3.461 |
| Serialized sample size, 264 bytes | 9.566 | 4.078 | 6.047 | 3.578 |
| Normalized configuration, 115 bytes | 9.425 | 4.152 | 6.047 | 3.465 |
| Distinct schema shapes, 990 bytes | 9.393 | 4.090 | 6.172 | 3.551 |
| 2,837 generated commands, 507,825 bytes | 54.519 | 16.001 | 13.422 | 8.102 |
| 10,000 HTTP + 10,000 fixtures, 860,080 bytes | 101.977 | 24.315 | 18.242 | 18.402 |

For the last two cases, jqz wall-time ranges were 54.326–57.584 ms and
98.189–103.065 ms; jq ranges were 12.515–17.401 ms and 23.279–25.683 ms.
All 34 timed cases had higher jqz median wall time. The larger report had
comparable peak RSS. Small cases are strongly affected by startup and process
supervision/capture. Scale fixtures preserve shapes/cardinalities, not original
payload bytes/distributions. Five repetitions, warm caches, Debug versus an
installed distribution binary, and these selected jobs do not establish general
performance advantages. The separate [phase profile](../profiling/README.md)
isolates engine phases and requested allocation capacity. Differences from
historical runs do not establish an engine speedup.

## Priorities supported by this sample

All four follow-up priorities are complete: serialization/sizing, immutable
configuration edits and sorted output, structural distinctness, and a measured
Debug profile. No selected observed workflow remains unsupported. The next work
is performance investigation guided by the [profile findings](../profiling/README.md):
subdivide parsing/DOM construction, isolate process/supervision overhead, and
investigate comparison-copy allocation for large structural sets before choosing
optimizations. Additional language features need new practical evidence.

## Historical standalone source and consumer (0.12.0)

[package-evidence.json](package-evidence.json) records the qualified 368,248-byte
source snapshot, archive/compiler/binary hashes, normalized commands and results.
Its archive SHA-256 is
`0412226d66bb709c641fc3e019b9b843eb005a0759785dcc882d2831766e0a08`;
an unchanged rebuild produced identical bytes. Caches/build outputs were excluded.
The archive was produced before its 0.12.0 result documents, so it is a
qualification snapshot. Its code, consumer main and corpus fingerprints match
the recorded 0.12.0 checkpoint. Current checkout verification is described above.

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
