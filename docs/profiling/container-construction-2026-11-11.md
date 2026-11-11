# Container construction, jqz 0.26.2

The [follow-up plan](../plans/2026-11-11-container-construction.md) is complete.
Against the frozen 0.22.0 builder, combined backend array-request traffic is 52%
lower and the full-parser backing peak is 22% lower. Exact `keys`/`map` storage
reduces repeated-schema source requests by 54%. Ordinary parser time remains
within the predeclared 5% bound; this work does not establish a general latency
improvement. Four rejected experiments remain reproducible, and stable block
sorting and its original comparator are retained.

All measurements use native x86_64 Linux Debug, Zig 0.17.0, CPU `znver4` and
Linux `7.0.0-42-generic`. New helpers are Zig and use existing dependencies; no
additional tool, architecture or optimization mode was required. The earlier
[0.22.0 performance report](performance-2026-11-11.md) remains historical evidence.

## Final evidence and reproduction

| Evidence | Checked observations |
| --- | --- |
| [Qualification](../qualification/2026-11-11-container-construction.json) | 45 cases, 340 process wall-time/RSS samples |
| [Ordinary engine phases](2026-11-11-container-construction.json) | 490 phase intervals and ten supervised null launches |
| [Current builder](2026-11-11-builder-final.json) | Ten inputs × six variants × 24 repetitions = 1,440 samples |
| [Parser experiments](2026-11-11-parser-container-final.json) | 490 samples, retaining the original standard-parser controls |
| [Materialization and sorting](2026-11-11-collections-final.json) | 3,072 component, full-sort-control and actual evaluator intervals |
| [Structural comparisons](2026-11-11-structural-container-final.json) | 800 intervals, retaining the earlier deep-copy controls |
| [Matched public CLIs](2026-11-11-invocation-container-final.json) | 276 launch, batching and 0.22.0/current CLI samples |

Source, tool and input/output fingerprints are recorded and checked. Benchmark
runners were sequential; each case has preflight/warm-up and checked output.
Builder/collection sequences balance both positions and directed predecessor
pairs per six repetitions. Earlier fixed-neighbor rotations and their follow-up
are preserved in the plan; they are not substituted for the final balanced run.

```sh
zig build
zig build test --summary all
(cd tests/package && zig build test --summary all)
zig build qualify -- --repeat 5 --out .zig-cache/qualification/containers.json
zig build profile -- --repeat 10 --out .zig-cache/container-phases.json
zig build profile -- --study builder --repeat 24 --out .zig-cache/builder.json
zig build profile -- --study parser --repeat 14 --out .zig-cache/parser.json
zig build profile -- --study collections --repeat 12 --out .zig-cache/collections.json
zig build profile -- --study structural --repeat 10 --out .zig-cache/structural.json
zig build profile -- --study invocation --reference-cli /absolute/path/to/jqz-0.22.0 --repeat 12 --out .zig-cache/invocation.json
```

The retained local baseline is `zig-out/performance-baseline/jqz-0.22.0`, SHA-256
`461abf174280cb39f4825e655f381107a39aabe5cd175fe4373e97d0ca4004ec`.
This ignored artifact can be recreated by building commit `9a5c90b` in a detached
checkout outside this project. Debug build paths can change binary hashes. The
measured current CLI is
`f44e898d423783745d4262e4319172ce5b3b556f62987b877d0692eb4baf1d1e`.

## Parser allocation and ownership

The [initial builder baseline](2026-11-11-builder-baseline.json) found backend
array growth requesting 4,705,792 logical bytes in 38 allocations, alongside
4,560,760 bytes for object storage. Interleaving array growth with child objects
strands old buffers in the parsed arena. Narrow probes separately attribute
token acquisition, array growth/appends, small-map duplicate checks, indexed
insertion, object finalization and arena seeding. Indexed insertion includes
hashing and growth rather than pretending to be a pure duplicate-check interval.

Arrays now buffer sixteen values on the stack. If that prefix or the first spill
item contains an allocating child, larger arrays use caller-allocated temporary
chunks of at most 1,024 values, copy once into exact arena-owned storage and
release all chunks on success or failure. Otherwise larger arrays retain ordinary
arena growth after the prefix, avoiding an unnecessary final duplicate. Late
allocating children remain correct on that selected path. Empty arrays skip finalization;
arrays without chunks skip the cleanup helper.

The standard validating Scanner, Parsed arena owner and EOF handling remain.
An explicit source adapter carries the caller allocator; it is not recovered
from Scanner internals. Plain tokens still borrow input, decoded escapes remain
owned, and retained collections deep-copy before `feed` returns.

The gate was recorded before coding: at least 50% less combined backend array
traffic and a 20% lower backing peak, with large-parser median time at most 5%
above paired references. Moving traffic to a different owner does not count as
a reduction:

| Input | Reference array requests | Current arena requests | Current temporary requests | Current combined requests | Reference/current backing peak |
| --- | ---: | ---: | ---: | ---: | ---: |
| Commands, 507,825 bytes | 1,169,280 B | 635,488 B | 171,392 B | 806,880 B | 4,223,391 / 3,868,573 B |
| Backend, 860,080 bytes | 4,705,792 B | 1,120,000 B | 1,146,048 B | 2,266,048 B | 10,517,879 / 8,223,471 B |

Backend traffic falls 52% and backing peak 22%; commands fall 31% and 8%.
Backing peaks include both simultaneously live owners and are requested capacity,
not RSS. Temporary counters include scanner storage separately from arena
requests, and temporary live bytes return to zero. Arena requests are reclaimed
in bulk. A caller allocator that retains individually freed memory can change
the temporary-storage benefit; these runs use the process GPA.

| Ordinary parse | Reference ms | Reference control ms | Current ms | Current control ms |
| --- | ---: | ---: | ---: | ---: |
| Commands | 25.314 | 25.426 | 26.154 | 25.579 |
| Backend | 51.750 | 51.554 | 52.643 | 52.169 |
| Escaped/nested/long numbers | 0.430 | 0.432 | 0.473 | 0.482 |
| Empty containers | 2.398 | 2.363 | 2.476 | 2.451 |

Command reference/current ranges are 23.338–27.584 / 23.310–28.840 ms; backend
ranges are 47.968–55.376 / 49.524–58.048 ms. Both large time gates pass, without
claiming a parser CPU gain. The escaped case differs by 0.042/0.049857 ms versus
paired references, below the 0.05 ms investigation threshold. Its backing peak
is 36,655 B versus 36,559/36,429 B; the independently measured temporary peak and
arena remap behavior explain this small increase. Flat/empty-container reference
peaks vary from roughly 1.32 to 1.99 MB between equivalent controls; current is
1.33 MB. Different initial growth capacity also explains the small increase
against the lower reference control. No universal peak reduction is asserted.

Counter-only/timed probes add substantial overhead: initial backend parses take
53.941 ms ordinarily, 60.959 ms with counters and 120.888 ms with clocks. Observed
timers also exclude arena-owner setup. Operation times are not an additive CPU
budget or a matched startup measurement; ordinary full-parser controls govern
acceptance. Ordinary execution specializes observation points away.

The [initial final audit](2026-11-11-builder-empty-check.json) flagged extra empty
array overhead. Removing unnecessary finalization/cleanup calls produced the
final 24-repetition run above. Boundary, allocation-failure and buffer-reuse
checks cover the changed paths.

## Known-size query materialization

`keys` and `map` now reserve their known final output count exactly. The gate
requires at least 20% less targeted logical traffic without higher backing peaks.
Evaluation order, diagnostics, filtering reservation and retention budgets remain
unchanged.

| Distribution | Reference/current source requests | Reference/current source peak | Reference/current full pipeline model peak |
| --- | ---: | ---: | ---: |
| Repeated schemas | 3,640,112 / 1,680,000 B | 6,002,172 / 2,109,224 B | 6,002,172 / 5,687,684 B |
| All distinct schemas | 252,112 / 112,000 B | 317,308 / 214,660 B | 771,094 / 575,962 B |

Repeated source requests fall 54%. The 65% source-peak decrease becomes a 5%
complete-pipeline decrease because later row allocation starts another arena
region. Actual evaluator peaks match the current models. Other distributions
retain their peaks. Source-model medians are 6.458/6.450 ms reference/control and
5.197/5.212 ms current/control. Actual source evaluation is 9.223 ms and full
evaluation 19.222 ms. Models omit AST/path traversal; their times cannot replace
actual evaluator times or establish a precise decomposition by subtraction.

Full-sort controls evaluate the actual source expression with current storage on
both sides, freezing only the sorter/comparator. They omit successful outer
`unique` path setup; ordinary evaluator intervals remain separate. All eight
distributions check source and result bytes against public execution. Sorted,
reverse and late-inversion cases contain 10,000 values in the final studies;
earlier 1,024-value baselines are labeled historical in the plan.

## Rejected experiments

| Candidate and evidence | Reason for rejection | Reproduction patch/base |
| --- | --- | --- |
| [Arena-only chunks](2026-11-11-builder-chunked-rejected.json) | Backend peak improves 19%, short of the 20% gate; flat scalar arrays also expose the final-copy cost. | [Patch](experiments/builder-chunked.patch), `ef4fe65` |
| [Sorted-input guard](2026-11-11-sort-guard-rejected.json) | Late-inversion full pipeline rises from 22.062 to 25.634 ms: 16% and 3.572 ms, beyond both regression thresholds. | [Patch](experiments/sort-guard.patch), `7d1c521` |
| [Same-tag rank bypass](2026-11-11-same-tag-rejected.json) | Repeated sort 6.807/7.341 ms reference/control versus 6.624/6.818 ms current/control misses the 20% target. | [Patch](experiments/same-tag-comparison.patch), `0423521` |
| [Inline primitive children](2026-11-11-primitive-child-rejected.json) | Paired repeated-sort gains are about 16%/11%, below 20%; ordinary full-query timing does not establish a uniform gain. | [Patch](experiments/primitive-child-comparison.patch), `f561c63` |

Each patch applies independently to its stated base and was checked there.
None is retained in production. There is no new row scan, sorting algorithm,
hash-based equality or cached comparison representation. The implementation
record links intermediate baselines and explains the predecessor-order correction.

## Complete invocation and qualification

Matched public CLI wall-time medians, with twelve repetitions and exact output:

| Projection | Original 0.22.0 ms | Current 0.26.2 ms | Current control ms |
| --- | ---: | ---: | ---: |
| Command count/tail | 45.313 | 45.787 | 43.473 |
| Backend count | 79.793 | 80.660 | 81.832 |
| Backend key arrays | 95.960 | 95.104 | 93.683 |
| Backend distinct schemas | 98.658 | 97.106 | 97.516 |

The ranges overlap: backend distinct schemas span 92.684–134.496 ms original and
89.844–105.275 ms current. These results do not justify a general CLI latency
improvement. Process intervals include launch, stdin/output capture, teardown and
scheduling; child allocator/RSS metrics are null. They are separate from the
GNU-time [qualification](../qualification/README.md), where installed jq 1.7
still has lower median wall time on all 34 timed cases. Debug versus an installed
binary with unknown build flags is not an optimized-build comparison.

Native Debug build and all 220 project checks pass: 158 language/library, 37 CLI,
four version-workflow, three qualification-runner and eighteen profiler checks.
All 220 executed on the final version; eight separate-package consumer checks
also pass. All 45 frozen corpus cases, 30 selected observed translations and ten
intentional probes remain unchanged and pass. All 340 qualification samples have
RSS. Final source/tool fingerprints and document links pass verification.

The final ordinary profile still spends 52.610 ms parsing versus 0.114 ms feeding
backend count. Distinct-schema reporting spends 51.885 ms parsing and 20.005 ms
feeding, with a 12.723 MiB live backing-capacity peak during feed. Complete-input
construction, actual expression/path work and stable structural sorting remain
costs. Further changes need new measured evidence and gates; the rejected simple
shortcuts do not justify broader algorithms or additional language syntax.
