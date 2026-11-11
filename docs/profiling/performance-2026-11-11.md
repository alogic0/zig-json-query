# Parser and structural-set performance, jqz 0.22.0

The [performance plan](../plans/2026-11-11-parser-and-runtime-performance.md) is
complete. Matched native Debug measurements show 47% less parser time on the
command fixture and 43% less on the backend fixture, with lower backing-memory
peaks. Complete CLI invocations on those inputs take about 33% less time than
jqz 0.18.1. Repeated-schema comparison preparation requests 71% fewer bytes and
its backing-memory peak is 42% lower. Query behavior and the selected workflow
coverage remain unchanged.

These results concern the selected inputs on this machine. In the separate
[qualification](../qualification/README.md), Debug jqz still has higher median
wall time than installed jq 1.7 on all 34 timed cases.

## Evidence and reproduction

All final runs use jqz 0.22.0, Zig 0.17.0, x86_64-linux-gnu Debug, CPU `znver4`
and Linux `7.0.0-42-generic`. Runners were sequential, with preflight/warm-up,
rotated case/variant order and exact output checks. Raw records preserve order,
ranges, source/input/tool hashes, queries and measurement boundaries.

| Final evidence | Checked measurements |
| --- | --- |
| [Workflow qualification](../qualification/2026-11-11-performance.json) | 45 cases; 340 wall-time/RSS samples |
| [Engine phases](2026-11-11-performance.json) | 490 phase intervals and ten supervised null-query launches |
| [Parser comparison](2026-11-11-parser-final.json) | Five inputs × seven variants × 14 repetitions = 490 samples |
| [Structural comparison](2026-11-11-structural-final.json) | Five distributions; 800 component/full-query samples |
| [Invocation comparison](2026-11-11-invocation-final.json) | 170 launch, batching and original/current CLI samples |

Run from the repository root:

```sh
zig build
zig build test --summary all
(cd tests/package && zig build test --summary all)
zig build qualify -- --repeat 5 --out .zig-cache/qualification/performance.json
zig build profile -- --repeat 10 --out .zig-cache/performance.json
zig build profile -- --study parser --repeat 14 --out .zig-cache/parser.json
zig build profile -- --study structural --repeat 10 --out .zig-cache/structural.json
zig build profile -- --study invocation --reference-cli /absolute/path/to/jqz-0.18.1 --repeat 10 --out .zig-cache/invocation.json
```

The original CLI was built in a temporary detached checkout at `e8dde1d`
(0.18.1). That checkout has been removed; its measured binary is retained locally
at `zig-out/performance-baseline/jqz-0.18.1`, SHA-256
`166c963e2d06d670be7518eeb020f8b3a69114d4afcb3ac99f60218911efe3d4`.
This ignored build artifact is optional: recreate the checkout outside the
project and run `zig build` there to obtain another reference binary. Raw
invocation evidence retains the original temporary path and hash. Debug build
paths can change binary hashes. The measured current CLI hash is
`461abf174280cb39f4825e655f381107a39aabe5cd175fe4373e97d0ca4004ec`.

All measurement helpers are Zig and reuse existing dependencies. The two minimal
launch controls are native Debug profiling helpers. No additional architecture,
optimization mode, external profiler or tool installation was needed.

## Parser: borrow tokens and reduce arena growth

The [initial parser study](2026-11-11-parser-baseline.json) found that the generic
Scanner defaults to borrowing, but `std.json.Value.jsonParse` explicitly asks for
`.alloc_always`. On the backend input, 110,007 copied tokens contain 510,043
decoded bytes but request 14,820,960 logical bytes. They account for 110,007 of
140,050 logical value-building allocation calls. Scan/copy takes 50.479 ms versus
19.376 ms for scan/borrow; the independent depth check takes 3.193 ms. These
experiments overlap full parsing and cannot be added or subtracted to obtain a
direct DOM-construction time.

The production adapter keeps the standard validating Scanner, arena ownership
and end-of-input checks. Plain tokens borrow the caller's input; escaped values
own their decoded storage. Up to four object fields are buffered before exact
map allocation; larger maps retain ordinary growth. Inputs of at least 64 KiB
seed the arena with a bounded 16 KiB reusable reservation. Collectors still
deep-copy retained values before `feed` returns.

The acceptance gate was recorded before implementation: at least 15% less parse
time on both large inputs and no large-input backing-memory regression. Other
timing regressions exceeding both 10% and 0.05 ms required investigation.

| Input | Reference ms | Same-reference control ms | Current ms | Reference peak bytes | Current peak bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| Null | 0.0062 | 0.0057 | 0.0060 | 32 | 32 |
| Small report, 990 bytes | 0.234 | 0.239 | 0.139 | 16,423 | 15,639 |
| Commands, 507,825 bytes | 49.661 | 48.764 | 26.340 | 9,900,333 | 4,223,391 |
| Backend, 860,080 bytes | 96.479 | 97.089 | 54.621 | 14,319,481 | 10,517,879 |
| Escaped/nested/long numbers, 6,401 bytes | 0.389 | 0.358 | 0.402 | 66,845 | 41,049 |

Large-case ranges are 47.628–56.974 ms reference versus 25.580–27.448 ms current
for commands, and 94.321–106.906 versus 52.940–57.728 ms for backend. Both gates
pass; backing peaks fall by 57% and 26%. The varied small case adds 0.013 ms
against reference, below the absolute investigation threshold. Its equivalent
reference/control peaks differ (66,845 versus 37,545 bytes), illustrating arena
growth/remap sensitivity; current is 41,049 bytes. No uniform small-case gain is
claimed.

Two candidates failed the large-input memory gate and were discarded:

| Experiment | Backend reference/current ms | Reference/current peak bytes |
| --- | ---: | ---: |
| [Borrow tokens only](2026-11-11-parser-rejected.json) | 94.230 / 58.707 | 14,319,481 / 15,226,867 |
| [Borrow and buffer small objects, without arena seed](2026-11-11-parser-compact-rejected.json) | 98.470 / 58.872 | 14,319,481 / 15,622,149 |

The [borrow-only patch](experiments/parser-borrow-only.patch) and
[buffered-object patch](experiments/parser-compact.patch) each apply independently
to instrumentation commit `6d9179b`. Both were checked with `git apply --check`
against that base. Earlier [initial accepted](2026-11-11-parser-optimized-initial.json)
and [balanced accepted](2026-11-11-parser-optimized.json) runs are retained; the
table above uses the final 0.22.0 run rather than comparing historical blocks.

## Structural sets: borrow canonical trees and compact distinct rows

The [structural baseline](2026-11-11-structural-baseline.json) separated source/key
materialization, comparison preparation, sorting and result storage. Before the
runtime change, the gate required at least 50% fewer preparation request bytes
and a 25% lower backing peak on repeated schemas. Every distribution also had
to avoid unexplained peak increases; timing regressions over both 10% and 0.5 ms
required investigation.

Comparison preparation now borrows already canonical values, copying unsorted
objects and only their changed ancestors. Original values remain available for
stable equal representatives. After sorting, distinct rows compact in place and
output reserves space for the distinct count. This shared ordering path serves
`unique`, `sort_values` and `-S`; no hashing was needed.

On repeated schemas, preparation falls from 10,001 logical allocations requesting
3,920,000 bytes to one row allocation requesting 1,120,000 bytes: 71% less traffic.
The stage backing peak falls from 10,273,456 to 6,002,172 bytes: 42% lower.
The final full-query comparisons include upstream materialization and the actual
evaluator, with parsing/query compilation and output serialization outside their
timed interval:

| Distribution | Reference ms | Reference control ms | Current ms | Reference peak bytes | Current peak bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| Repeated schemas | 25.812 | 26.023 | 22.480 | 10,273,456 | 6,002,172 |
| All distinct | 2.394 | 2.383 | 2.143 | 771,094 | 771,094 |
| Mixed JSON values | 4.413 | 4.397 | 3.934 | 429,718 | 168,072 |
| Nested, ordered | 13.586 | 13.590 | 10.016 | 1,416,466 | 168,072 |
| Nested, unordered | 13.927 | 14.360 | 13.470 | 1,416,466 | 827,028 |

Repeated-schema time ranges are 24.482–28.201 ms reference and 21.702–23.756 ms
current. All distributions improve in this run and none raises the backing peak.
The [initial accepted comparison](2026-11-11-structural-optimized.json) is also
retained. Logical requests inside an arena and backing capacity are separate
metrics; the reductions above are not process RSS claims.

## Invocation controls and existing batching interfaces

In the final invocation run, empty-Zig and matched-echo medians are both 6.327 ms;
current null is 8.801 ms, its same-binary control 8.550 ms and original null
8.682 ms. Empty-Zig spans 6.070–8.986 ms; current null spans 8.202–13.282 ms.
These intervals include process initialization, supervision, IO and scheduling.
They do not isolate loader time or identify a safe startup runtime change, so
none was made.

Sixteen equivalent report projections take 154.095 ms across separate processes,
13.228 ms in one multi-file invocation, 12.837 ms as NDJSON, 4.634 ms with one
compiled Program and separate sessions, or 3.814 ms with one session. All emit
the same ordered results. The projection has no aggregate or early-stop scope
ambiguity. These are existing interfaces; no daemon or new public API was added.
In-process intervals include the instrumented writer/check/cleanup work; CLI
intervals use parent-observed process completion. Child memory is unavailable
here and remains null in the evidence.

The original and current public CLIs were also alternated on both large inputs:

| Count projection | Original 0.18.1 ms | Current 0.22.0 ms | Same-current control ms | Original/current ranges ms |
| --- | ---: | ---: | ---: | --- |
| Commands | 66.436 | 44.330 | 42.639 | 62.884–68.449 / 39.503–46.541 |
| Backend | 121.714 | 81.794 | 80.846 | 117.854–130.472 / 76.572–85.488 |

Both complete invocations improve by about 33%, beyond same-current variation.
Their process timings include stdin and output capture. The earlier
[0.20.0 invocation study](2026-11-11-invocation.json) remains available separately.

## Verification and remaining costs

Native Debug build and 210 project checks pass: 154 language/library, 37 CLI,
four version-workflow, three qualification-runner and twelve profiler checks.
The final full invocation ran 198 checks and reused twelve valid cached profiler
checks. Eight separate-package consumer checks pass on 0.22.0. Differential
parser tests cover malformed input, UTF-8/surrogates, decoded duplicate keys,
diagnostic offsets, exact numbers, map sizes, depth and allocation failures.
Ownership checks reuse caller buffers and exercise retained collections.
Structural checks cover canonical borrowing, unchanged siblings/originals,
distinct output capacity, allocation failures, exact numeric equality and stable
representatives. The full 45-case corpus preserves 30/30 selected observed
translations and ten intentional probes against unchanged frozen expectations.
Final source/tool fingerprints match the measured files.

The final ordinary phase profile still spends 25.656 ms parsing versus 0.071 ms
feeding the large command count, and 53.149 versus 0.067 ms for backend count.
The repeated-schema report spends 53.161 ms parsing and 21.907 ms feeding, with
a 15.757 MiB live backing-capacity peak during feed. Remaining candidates are
complete-document construction and upstream key-array materialization/sorting,
if future work warrants them. Additional query syntax needs new workflow evidence.

The authorized [container-construction follow-up](../plans/2026-11-11-container-construction.md)
records the next implementation slices and their measurement gates.

Instrumentation, an allocating output writer, allocator state, warm caches,
selected repetitive distributions and one machine limit these measurements.
Scanner experiments overlap; structural full-query intervals exclude parsing;
process wall time includes supervision. Historical phase/qualification reports
remain unchanged and are not a matched speedup baseline. No optimized-build,
cold-start, general jq replacement-rate or general performance claim follows.
