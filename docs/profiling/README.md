# Native Debug phase profile

The completed [0.26.2 container-construction report](container-construction-2026-11-11.md)
records accepted parser/materialization memory reductions, rejected sorting
experiments and final verification. Its linked raw runs are the latest evidence.
The earlier [0.22.0 report](performance-2026-11-11.md) and the phase tables below
preserve historical results; these tables are the original 0.18.1 baseline.

[2026-11-11.json](2026-11-11.json) records jqz 0.18.1, Zig 0.17.0,
x86_64-linux-gnu, CPU `znver4`, Linux `7.0.0-42-generic`. This completes the
profiling slice of the [implementation plan](../plans/2026-11-10-remaining-workflows.md).
The separate [workflow qualification](../qualification/README.md) records output
equivalence and standalone-process wall time/RSS against jq.

## Reproduce and scope

```sh
zig build test
zig build profile -- --repeat 10 --out .zig-cache/profile.json
```

The runner uses existing Zig test-support process/file helpers. It measures
seven cases with ten repetitions after one preflight/warm-up each, rotating
case order. Inputs are loaded/generated before measurement. The command input
has 2,837 records (507,825 bytes); the backend input has 10,000 HTTP records and
10,000 fixtures (860,080 bytes). Both generated hashes match the qualification
inputs. Small fixtures are the same sanitized files used there. No private
session storage, new external profiler, interpreter or additional build mode is
required.

Seventy in-process runs produce 490 phase samples. Phases follow the public
execution order: query compilation, session setup, strict document parsing,
feed/evaluation, parsed-document release, stream completion/emission, cleanup.
The same `input.zig` parser is used by ordinary feeds, including size/depth,
duplicate-key and exact-number handling. Every measured output matches ordinary
`Program.run` byte-for-byte, and all final tracked live-byte counts are zero.
Ten additional supervised null-input CLI launches check output/exit status.

Timers use the monotonic awake clock. The allocator meter wraps `Init.gpa` and
counts successful backing requests and positive resize/remap growth. Arena
capacity is included; per-value allocation calls inside an arena and allocator
metadata are not counted separately. Phase peaks include storage already live
at phase start; the raw records include start/end live bytes. These are requested
capacities, not process RSS. Preloaded input bytes, expected outputs, file IO and
report allocations are excluded. Output uses an allocating writer, so emission
costs differ from buffered stdout. Debug instrumentation and allocator state
affect the observations; warm repetitions do not establish cold-start or
optimized-build behavior. Source, input, compiler, CLI and profiler hashes are
recorded and checked for changes during the run.

## Measured costs

All times below are milliseconds. Phase columns are medians of their individual
samples. The total column is the median of each run's summed seven intervals;
it excludes gaps between phase timers and need not equal the displayed medians'
sum. Feed peak is median live requested capacity during feed, including the
parsed document and compiled query already live at its start.

| Case | Parse ms | Feed/evaluate ms | Total phase ms | Feed peak MiB |
| --- | ---: | ---: | ---: | ---: |
| Null identity, 5 bytes | 0.012 | 0.010 | 0.097 | 0.002 |
| Small report, 990 bytes | 0.264 | 0.063 | 0.478 | 0.028 |
| Command count/tail, 507,825 bytes | 44.997 | 0.080 | 45.913 | 9.445 |
| Large report count, 860,080 bytes | 87.146 | 0.079 | 88.424 | 14.416 |
| Large report filter | 86.262 | 14.836 | 102.889 | 14.861 |
| Large report distinct schemas | 86.409 | 25.574 | 112.290 | 23.452 |
| Large report JSON encoding/size | 87.009 | 19.964 | 108.062 | 16.730 |

Query compilation medians range from 0.042 to 0.108 ms. Session setup ranges
from 0.011 to 0.025 ms. Releasing large parsed inputs costs 0.647–0.976 ms;
completion and remaining cleanup are small for these nonretaining projections.
The regression checks also exercise retained completion, where document release
precedes aggregate emission just as in ordinary streams.

| Case | Parse backing allocations | Parse requested MiB | Feed backing allocations | Feed requested MiB |
| --- | ---: | ---: | ---: | ---: |
| Command count/tail | 18 | 9.442 | 2 | 0.001 |
| Large report count | 16 | 14.411 | 2 | 0.002 |
| Large report filter | 16 | 13.656 | 2 | 1.202 |
| Large report distinct schemas | 15 | 13.652 | 5 | 9.798 |
| Large report JSON encoding/size | 16 | 15.295 | 7 | 1.433 |

Counts/capacities are medians, including arena growth. Identical backend inputs
can have different requested capacity as query and allocator state affect arena
growth/remap opportunities; the table does not attribute that difference to
different payloads.

Supervised null-input CLI wall time is 15.039 ms median, ranging from
12.934 to 19.634 ms. Its measured in-process engine phases total 0.097 ms median.
The larger interval includes process/runtime initialization, stdin/output
capture, supervision and scheduling, as well as engine work. It cannot identify
which of those costs dominates without a controlled launch baseline.

## Original findings and completed experiments

The [parser/runtime performance plan](../plans/2026-11-11-parser-and-runtime-performance.md)
completed these investigations in 0.22.0. The
[performance report](performance-2026-11-11.md) explains their controls, accepted
changes and remaining costs. The following priorities describe the original
0.18.1 observations that motivated that plan.

1. Whole-document parsing dominates the selected large count projections.
   Split depth scanning, JSON tokenization, DOM construction and arena growth
   measurements before selecting parser or incremental-input changes. Existing
   parsing still validates/builds the complete document before projection.
2. Tiny jobs spend most observed wall time outside the measured engine phases.
   Compare a minimal Zig process under the same supervision, then compare the
   existing multi-file/NDJSON and compiled-Program reuse paths. This can separate
   process/harness effects from useful engine changes.
3. Structural schema uniqueness adds 25.574 ms of feed work and 9.798 MiB of
   successful new capacity requests on the repeated fixture. Measure key-array
   materialization, ordered comparison copies and sorting separately before
   choosing caching or a different deduplication strategy. Preserve exact
   numeric equality, sorted results and first original representatives.

These were investigation priorities, before the matched implementation studies.
The inputs are selected and highly repetitive, the build is Debug, and the
instrumented writer/meter differ from an ordinary CLI invocation. Profiles
were run after qualification, without overlapping benchmark runners.
