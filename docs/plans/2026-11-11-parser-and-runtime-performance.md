# Parsing, invocation overhead and structural-set memory

Status: completed on 2026-11-11 in jqz 0.22.0; authorized on 2026-11-11.

## Objective and baseline

Implement the next experiments from the [phase profile](../profiling/README.md),
following the completed [workflow plan](2026-11-10-remaining-workflows.md).
First identify and reduce the largest measured parsing cost. Then isolate
process/supervision overhead and reduce structural-uniqueness scratch memory.

The frozen baseline is jqz 0.18.1 with Zig 0.17.0, native x86_64 Linux Debug:

| Selected case | Existing observation |
| --- | --- |
| Large report count, 860,080 bytes | 87.146 ms parsing; 0.079 ms feed/evaluation |
| Command count/tail, 507,825 bytes | 44.997 ms parsing; 0.080 ms feed/evaluation |
| Null identity | 0.097 ms summed engine phases; 15.039 ms supervised CLI median |
| Large report distinct schemas | 25.574 ms feed work; 9.798 MiB new feed requests; 23.452 MiB live-request peak during feed |

These are historical Debug measurements, not promised improvement targets.
The [raw profile](../profiling/2026-11-11.json) and
[workflow evidence](../qualification/2026-11-11-remaining-workflows.json) remain
unchanged. Establish a fresh matched baseline before evaluating candidates.

## Scope and contracts

- Use Zig for new implementation and measurement helpers. Reuse the pinned
  test-support/process tooling and existing fixtures. Check
  `/home/oleg/zig-inventory-2026-11-03` before adding a dependency; report a missing
  required tool by name. Do not modify the installed standard library or sibling
  provider repositories as part of an experiment.
- Use native x86_64 Linux Debug: `zig build` and `zig build test`. No routine
  optimization-mode matrix or additional architecture is part of this plan.
- Preserve exact number tokens, strict missing/type rules, duplicate-key and
  UTF-8 validation, insertion/array order, admission/depth limits and diagnostic
  byte offsets, lines, columns and source paths. Unused document fields remain
  validated before output. Existing early-stop rules for skipped input remain.
- Preserve borrowed-input lifetimes, owned bindings/slurp, downstream retention
  copies, shared collection budgets and failure/cleanup behavior. Do not trade
  validation or ownership for benchmark speed.
- Structural results retain total JSON ordering, exact numeric equality and
  the first original equal representative. Existing stream sort/group rules
  and `-S` output bytes remain unchanged.
- Instrumentation stays in profiling/experimental paths, without clocks or
  request counters on the ordinary production path. This plan adds no new query
  syntax, daemon, JIT or incremental document-emission contract.

## Measurement rules

1. Pin source, compiler, binaries, flags, fixtures, environment and commands for
   both baseline and candidate. Keep a reproducible baseline artifact while
   changing the candidate. Preserve fixture/query/output hashes and raw samples.
2. Run baseline-versus-baseline controls to establish normal variation. Use
   warm-up, rotated/alternating order and at least ten repetitions per case.
   Keep benchmark runners sequential. Compare the same workload and output;
   report medians, ranges, request counts and memory peaks with their units.
3. Label direct measurements separately from differential experiments. A
   scan-only pass overlaps full parsing and does not enforce object duplicate
   rules by itself; subtracting its time is not a direct DOM-construction timing.
   Do not add overlapping timings or subtract unrelated medians as a precise
   decomposition. Report instrumentation overhead and unresolved components.
4. Distinguish logical allocation requests inside an arena, backing allocator
   capacity and process RSS. If measuring above and below an arena, report the
   levels separately and account explicitly for bulk region reclamation.
5. Choose and record each candidate's success criterion from the baseline noise
   before implementing it. Retain an optimization only when the targeted gain
   repeats beyond control variation and overall time/memory show no material
   unexplained regression on the other representative cases.
6. If a candidate fails those gates, discard the candidate, keep its measurements
   and explain the result. Complete a bounded investigation without claiming an
   optimization that the evidence does not support.

## Verified implementation slices

Each slice is checked and committed before the next begins. Measurement support
and runtime optimizations are separate commits.

1. [x] Record this plan and link it from the profiling findings/project docs.
2. [x] Extend parsing measurements in `tools/profile.zig` and `src/input.zig`:
   - Time the existing depth pass and full strict parser separately. Add a
     profiling-only scanner/token-consumption experiment with token/string/
     container counts, and distinguish it from a fully validated parse.
   - Measure DOM/container request traffic and backing-arena growth separately
     where the standard parser API permits. A profiling-only adapter using the
     same parser with an explicit arena is preferable to copying the JSON parser.
     Check its values, token spellings, order, errors and diagnostics against the
     ordinary parser. Do not claim per-value counts from the existing meter alone.
   - Check small reports and both scale inputs, plus bounded variations in
     escaping, Unicode, long number tokens, nesting and object/array shapes.
     Validate malformed/duplicate input independently of timing runs.
   - Record the component breakdown, measurement overhead and the largest
     actionable cost. Commit the verified instrumentation and baseline evidence.
3. [x] Implement the highest-value measured parser improvement as a focused
   runtime slice:
   - Evaluate a bounded change to the identified hot operation, such as container
     capacity growth, repeated work or token/value handling. The installed Zig
     scanner already defaults to `.alloc_if_needed`; assigning that same option
     explicitly is not a new borrowing optimization.
   - Keep any experimental parser adapter behind the shared strict input boundary.
     A parser replacement or selective/incremental engine requires evidence and
     a separately expanded design; it is not the default response to these data.
   - Verify decoded/escaped strings, exact numbers, duplicate/malformed/unused
     fields, limits and locations, NDJSON/multiple-file behavior and early stops.
     Use independent expected outputs, retained-buffer lifetime tests and
     allocation-failure checks for changed ownership paths.
   - Run matched before/after measurements, retain only a passing candidate,
     execute the functional checks and commit the accepted runtime change.
4. [x] Add controlled invocation-overhead measurements:
   - Build minimal Zig exit and matched stdin/stdout baseline executables with
     the same compiler, mode and initialization conventions as jqz. Launch them,
     `jqz --version` and the null query through the same supervision/capture path.
     Check exact output/status and pin every executable's hash.
   - Where useful, collect a child-reported work interval with its boundaries
     stated. Parent-observed wall time still includes initialization, teardown,
     IO and scheduling; a difference alone does not identify loader cost.
   - Compare repeated small document invocations with one multi-file command,
     one NDJSON command and a reused compiled `Program`. Use a projection without
     aggregates/early stops so all variants process the same values and emit the
     same ordered results. Report total/per-document time and cleanup behavior.
   - Document when existing batching/reuse helps. Change startup/runtime code
     only if these controls identify an actionable cost, using a separately
     verified runtime commit. Commit the measurement support/results first.
5. [x] Break down structural-set memory and execution:
   - Measure `keys`/`map` result creation, ordered comparison copies, sorting,
     deduplication and result storage separately, preserving the public pipeline
     lifetime. Include the existing repeated schemas plus all-distinct, mixed,
     nested and already ordered values; keep distribution labels in the evidence.
   - Record logical versus backing requests and live peaks for each component.
     Include end-to-end `unique(map(.fixtures,keys(.)))` results so an isolated
     microbenchmark cannot hide upstream materialization cost.
   - Commit verified instrumentation and a fresh baseline before optimization.
6. [x] Implement and measure a bounded structural-set improvement:
   - First evaluate borrowing already ordered comparison values and copying
     ancestor containers only when key ordering requires a change. Check the
     shared `json_order.zig` users: `unique`, `sort_values` and `-S`.
   - Consider deduplication before comparison-copy allocation only if the measured
     distribution supports it. Any hashing must normalize numbers/objects, verify
     collisions with exact equality, validate every input value and preserve the
     first original representative before producing sorted results.
   - Test equal numeric spellings, negative zero, object insertion order, nested
     arrays, exponent/depth failures, stable representatives, caller-buffer reuse
     and allocation cleanup. Apply the same time/memory regression gates to
     repeated and all-distinct inputs; commit only accepted runtime improvements.
7. [x] Complete native Debug build/tests and separate-consumer verification.
   Run the full workflow qualification at five repetitions and the matched
   performance suite at the established repetition count. Preserve all 30
   selected observed translations, all 45 existing corpus cases and ten intentional probes
   with unchanged frozen expectations; performance experiments do not increase
   observed-workflow coverage. Extend meaningful focused checks as needed.
   Publish new raw evidence and a report distinguishing accepted improvements,
   rejected experiments, remaining costs and measurement limits. Update links
   and plan status, then commit the final evidence slice.

Before each fix/feature commit, run `zig build version` and use
`zig build version -- set <new_sem_ver>` for the appropriate patch/minor increment.
Keep major 0 and include all updated markers. New profiling capabilities use a
minor increment; internal performance fixes use a patch increment when behavior
is preserved. Write complete commit messages to temporary files, commit with
`git commit -F`, and remove temporary files with plain `rm` when no longer needed.

## Acceptance and completion

The final report identifies the dominant parser components, bounds invocation
overhead with controlled comparisons, and explains structural-set request/peak
costs. Every accepted optimization has a reproducible improvement beyond control
variation, preserved semantics/ownership and no unexplained material regression.
Negative experiments are recorded honestly. All functional checks pass in the
one routine mode; historical evidence remains intact. No fixed speedup, RSS
reduction or support for unseen jq workflows is promised by the existing sample.

## Initial planning validation

Reviewed the current input/parser boundary, structural comparison-copy path,
profiling harness, pinned Zig parser allocation defaults and completed evidence.
At the initial documentation commit, runtime/profiler changes, new benchmark
runs and implementation checkboxes remained pending.
Linked repository documents and `git diff --check` were verified. No package
version increment is needed for this documentation-only slice.

## Implementation evidence

Slice 2, 0.19.0: [parser baseline](../profiling/2026-11-11-parser-baseline.json)
records 350 samples across five inputs and seven rotated experiments. Standard
and control are equivalent reference parses; scanner-only work is explicitly
separate. The instrumented standard DOM has independent logical/backing counters
and nested token-allocation traffic. Its values, order, spelling, error classes
and source diagnostics match the ordinary standard parser; allocation-failure
cleanup is checked.

The generic Scanner default borrows when possible, but Zig 0.17.0's dynamic
`Value.jsonParse` explicitly requests `.alloc_always`. On the backend fixture,
110,007 copied tokens contain 510,043 decoded bytes yet cause 14,820,960 logical
request bytes. Of 140,050 value-building allocation calls, 110,007 are token
acquisitions. Scan/copy median is 50.479 ms versus 19.376 ms with borrowing;
these are overlapping scanner experiments, not a subtraction from DOM time.
Depth checking is 3.193 ms and full reference parsing about 103 ms. Native Debug
build and all 199 project checks pass; source fingerprints match the measurement.

Decision before slice 3: evaluate a small value-construction adapter over the
unchanged validating Scanner, reusing standard arena/EOF handling. Preserve all
validation and diagnostic behavior. Accept only a repeatable median parser gain
of at least 15% on both large inputs (above the observed reference/control
variation), with no large-input memory regression. Investigate other-case timing
regressions exceeding both 10% and 0.05 ms; do not silently accept them. This
targets measured copying/builder work without replacing JSON tokenization or
changing the document-emission contract. An independent baseline checkout at
commit `e8dde1d` retains the original CLI for final process comparisons.

Slice 3, 0.19.1: a complete-input value adapter reuses the standard validating
Scanner, parsed arena owner and EOF checks. It borrows plain tokens, owns decoded
escapes, buffers up to four fields before exact map allocation, and uses a bounded
16 KiB arena reservation on inputs at least 64 KiB. Duplicate detection retains
the standard location/timing after completing each field value.

Two rejected variants and patches are preserved: borrowing alone raised backend
backing peak from 14,319,481 to 15,226,867 bytes; small-object buffering alone
still failed that gate. The accepted region/builder combination has fourteen
balanced rotations (490 samples) in the [matched comparison](../profiling/2026-11-11-parser-optimized.json).
Command parsing is 25.452 ms versus 48.585 ms reference, with peak 4,223,391 versus
9,900,333 bytes. Backend parsing is 52.522 versus 92.036 ms, with peak 10,517,879
versus 14,319,481 bytes. Both exceed the predeclared 15% time gate and reduce
memory. The escaped/nested case is 0.436 versus 0.422 ms reference; its 0.014 ms
absolute difference is below the 0.05 ms investigation threshold. An initial
ten-repetition block is retained; the balanced follow-up investigated the
reference/control variation rather than hiding it.

Native Debug build, 204 project checks and eight consumer tests pass. Differential
checks cover malformed/UTF-8/duplicate errors and locations, small/indexed maps,
exact tokens, retained caller buffers and allocation failures including the
large-document region branch. The 45-case corpus smoke passes all 30 observed
translations and ten probes. Source hashes match the accepted measurement.

Slice 4, 0.20.0: [invocation evidence](../profiling/2026-11-11-invocation.json)
has 110 checked samples, native Debug empty/echo binaries, current/version/null
controls and the pinned original 0.18.1 CLI. Empty/echo medians are 6.106/6.079 ms;
current null is 8.309 ms, its same-binary control 8.324 ms and original null
8.276 ms. These bound combined process/runtime/supervision costs; they do not
isolate loader time or identify a safe startup-code change, so none was made.

Sixteen equivalent report projections take 135.828 ms across separate processes,
11.544 ms with multiple files, 11.482 ms as NDJSON, 3.887 ms with one compiled
Program and separate sessions, or 3.144 ms with one reused session. All outputs
and statuses match; in-process cleanup reaches zero live requests. The projection
has no aggregate/early-stop ambiguity. Child allocator/RSS metrics are null;
in-process requests are measured. Build and 205 project checks pass. The existing
batch/reuse interfaces address the measured cost without a new daemon/API.

Slice 5, 0.21.0: [structural baseline](../profiling/2026-11-11-structural-baseline.json)
records 750 checked samples across repeated schemas, all-distinct schemas, mixed
values and ordered/unordered nested values. Components preserve stage lifetime
and separate map/key materialization, validated comparison preparation, stable
sort, result reservation and dedup/fill; full reference/control/current queries
agree byte-for-byte. Logical phase deltas are separate from backing peaks and
bulk arena release. Native Debug build and 206 checks pass.

Repeated schemas use 10,001 preparation allocations and 3,920,000 logical new
bytes, on top of upstream materialization; backing peak is 10,273,456 bytes.
The unchanged full-query medians are 23.020/23.279/22.906 ms. Before slice 6,
require at least 50% less preparation request traffic and 25% lower backing peak
on that distribution. Across every distribution, investigate full-query time
regressions exceeding both 10% and 0.5 ms or any unexplained backing-peak increase.
First evaluate borrowing already canonical trees and sizing unique output to its
distinct count. Hash-based deduplication is unnecessary unless these bounded
changes fail the gates; equality/representative rules remain mandatory.

Slice 6, 0.21.1: canonical comparison values now borrow their original tree.
Only changed ancestors and unsorted objects allocate; exact map storage is
reindexed through the public API. Stable distinct rows compact in place before
reserving output. There is no hash/dictionary equality shortcut.

The [matched structural comparison](../profiling/2026-11-11-structural-optimized.json)
has 800 samples with actual evaluator controls. Repeated-schema preparation falls
from 10,001 logical allocations / 3,920,000 bytes to one row allocation /
1,120,000 bytes (71% less traffic). Backing peak falls from 10,273,456 to 6,002,172
bytes (42% lower). Full query median is 18.309 ms versus 20.870 ms reference;
all-distinct, mixed and both nested distributions improve without a peak increase.
Both memory gates pass. Source materialization and sorting remain measurable
costs; their memory was not hidden by an isolated preparation benchmark.

Native Debug build, all 210 project checks, eight consumer tests and the complete
45-case corpus smoke pass. Added checks prove allocation-free canonical borrowing,
unchanged siblings/original values, output capacity following distinct count and
cleanup at every logical allocation in a partially copied region. Existing exact
equality, representative, invalid-exponent/depth and generated-model checks pass
for `unique`, `sort_values` and sorted output. Source fingerprints match the run.

Public-process comparison support, 0.22.0: the invocation study now alternates
the original CLI, current CLI and a same-current control on both large fixtures.
The [170-sample invocation run](../profiling/2026-11-11-invocation-final.json)
checks real stdin/output/exit behavior against ordinary execution. Command count
median is 44.330 ms current versus 66.436 ms original; backend count is 81.794
versus 121.714 ms, about 33% lower in each case. Current controls are 42.639 and
80.846 ms. This confirms the complete invocation benefits while keeping its
combined startup/IO/supervision costs explicit. Twelve profiler checks pass.

Slice 7, final 0.22.0 verification: native Debug `zig build` and `zig build test`
pass all 210 project checks (198 executed in the final full invocation, twelve
valid cached profiler checks), plus eight separate-package consumer checks.
The [full qualification](../qualification/2026-11-11-performance.json) preserves
all 45 corpus cases, 30/30 selected observed translations and ten intentional
probes against unchanged frozen expectations. All 340 timed samples have RSS.

The final [phase profile](../profiling/2026-11-11-performance.json) records 490
phase intervals and ten null-query launches; the
[parser comparison](../profiling/2026-11-11-parser-final.json) has 490 samples,
the [structural comparison](../profiling/2026-11-11-structural-final.json) 800,
and the original/current invocation comparison 170. Final parser medians are
26.340/54.621 ms versus 49.661/96.479 ms reference on commands/backend. Repeated
structural preparation still requests 71% fewer bytes with a 42% lower backing
peak, and all five full-query distributions improve without a peak increase.
The predeclared gates pass. Source and tool fingerprints match the evidence;
historical raw evidence and frozen corpus files remain unchanged.

The [completed report](../profiling/performance-2026-11-11.md) records accepted
changes, both rejected reproducible parser patches, launch/batching limits,
remaining costs and reproduction commands. The original 0.18.1 binary is retained
as an ignored local artifact after removing its temporary checkout. Launch
controls did not justify a startup runtime change; bounded structural borrowing
and compaction passed without hash-based deduplication. No new query syntax,
external tool or extra build mode was needed. Documentation links and
`git diff --check` pass; this final evidence/documentation slice keeps 0.22.0.
