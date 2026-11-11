# Session-derived workflow qualification

The [implementation plan](../plans/2026-11-10-workload-qualification.md) tracks
this checkpoint. [2026-11-10.json](2026-11-10.json) contains behavior checks,
queries/flags, source/fixture/binary hashes, raw samples and summaries for jqz
0.12.0 versus installed jq 1.7. The [corpus notes](../../tests/qualification/README.md)
explain source recovery, sanitization and reconstruction limits.

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
| Equivalent translated cases | 25 |
| Unsupported observed cases | 5 |
| Invocation adaptations included above | 1: argument-only construction needs a null input document |
| Isolated supported components | 2, outside observed-case coverage |
| Intentional semantic/exit probes | 7, all match their separate expectations |
| Generated scale cases | 2, outside observed-case coverage |
| Timed equivalent cases | 28 |
| Samples | 280: 28 cases × 2 tools × 5 repetitions |

Every reference and candidate was preflighted against frozen expectations before
timing. Unsupported jobs have checked jq results and no asserted jqz translation.
The null-input adaptation is not timed because input handling differs. This is a
deliberately chosen, unweighted sample: 25/30 is not a replacement rate for all
session invocations or general jq. Window/component adaptations are recorded per
case. Available private inputs were structurally inspected; missing backend
inputs were reconstructed from captured summaries and queries.

## Behavior differences

Checks preserve result/array ordering and exact decimal values while ignoring
object key order and numeric spelling (`1.5` equals `1.500000`). Raw output is
byte-exact. Separate probes establish false-default, missing-field, group-order,
large-integer arithmetic, duplicate-key, explicit-rounding and error-exit
differences. jqz keeps its documented contracts in every probe.

The compiler-status translation supplies an explicit optional default. Screenshot
and fault selection spell out jq truthiness. An explicit sort matches jq's group
order for standalone grouped counts; the embedded full summary remains a gap.

## Native Debug measurements

Target: x86_64-linux-gnu, CPU model `znver4`, Zig 0.17.0. jqz is Debug; installed
jq build flags are unknown. GNU time reports version `UNKNOWN`, so its SHA-256
is recorded alongside both query tools. Each median has five repetitions. RSS
was available for all 280 samples.

| Case | jqz median ms | jq median ms | jqz median RSS MiB | jq median RSS MiB |
| --- | ---: | ---: | ---: | ---: |
| Report summary, 990 bytes | 10.769 | 5.311 | 5.926 | 3.543 |
| Compiler-call count, 523 bytes | 13.062 | 4.317 | 6.090 | 3.527 |
| Timing mean, 65 bytes | 9.755 | 4.218 | 5.934 | 3.527 |
| 2,837 generated commands, 507,825 bytes | 64.775 | 16.464 | 13.301 | 8.141 |
| 10,000 HTTP + 10,000 fixtures, 860,080 bytes | 108.746 | 30.208 | 18.105 | 18.465 |

For the last two cases, jqz wall-time ranges were 60.097–73.927 ms and
105.866–110.326 ms; jq ranges were 13.786–18.479 ms and 27.703–44.188 ms.
All 28 timed cases had higher jqz median wall time. The larger report had
comparable peak RSS. Small cases are strongly affected by startup and process
supervision/capture. Scale fixtures preserve shapes/cardinalities, not original
payload bytes/distributions. Five repetitions, warm caches, Debug versus an
installed distribution binary, and these selected jobs do not establish general
performance advantages. This run does not isolate parsing/allocation costs.

## Priorities supported by this sample

1. Scalar array grouping/counts and exact totals inside object fields, covering
   `embedded-group-summary` and `embedded-total-summary` while retaining report
   context. Their individual stream components already work.
2. JSON serialization with explicit byte/character sizing, for
   `serialized-sample-size`; its ASCII fixture does not settle Unicode sizing.
3. Targeted deletion preserving arbitrary fields and sorted-key output, for
   `normalize-config`.
4. Structural-array ordering/distinctness, for `distinct-schema-shapes`.
5. Profile Debug startup and parsing/allocation on representative larger payloads
   before choosing engine optimizations or incremental parsing work.

Constant suffix matching and scalar schema-key unions already translate through
regex and grouping/sorting. Helpers could shorten those queries, while the five
listed gaps require additional capabilities.

## Standalone source and consumer

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
