# Container construction and structural materialization

Status: authorized implementation in progress, starting from jqz 0.22.0.

## Objective and evidence

Follow the completed [parser/runtime plan](2026-11-11-parser-and-runtime-performance.md)
and its [performance report](../profiling/performance-2026-11-11.md). The final
native Debug profile spends 53.149 ms parsing the large backend count and
0.067 ms evaluating it. Repeated-schema queries additionally spend about
11.152 ms materializing key arrays and 8.456 ms sorting rows. These historical
observations identify investigation targets, not promised gains.

Measure the current builder's token acquisition, array growth/appends, small-map
duplicate checks, indexed-map insertion and final object storage separately.
Implement only changes supported by those measurements. Afterwards investigate
known-size query array materialization and already ordered structural rows.

## Contracts and measurement rules

- All new implementation and measurement helpers are Zig. Reuse the current
  scanner, dependencies, allocation meter, process helpers and sanitized fixtures.
  No additional tool is currently required. Consult the existing inventory before
  adding one, and identify a missing required tool explicitly.
- Build and test native x86_64 Linux Debug only: `zig build` and `zig build test`.
  No architecture or build-mode matrix is part of this work.
- Preserve complete-input validation, exact number tokens, escaped/UTF-8 string
  handling, decoded duplicate keys, insertion/array order, byte/depth limits and
  diagnostic offsets/lines/columns/paths. Unused fields remain validated.
- Preserve input lifetimes, retained copies, shared collection budgets, early
  stopping, source provenance and cleanup on allocation/output errors.
- Structural sorting retains total JSON order and the first original equal
  representative. Validate every value before a sorted-input shortcut. No hash
  equality, new syntax, selective parsing, scanner replacement or stage fusion is
  presumed necessary.
- Retain the 0.22.0 CLI with its hash. Freeze a small 0.22.0 builder reference for
  comparisons within one process. Pin measured source, tools, input/output hashes
  and commands; preserve historical evidence and corpus expectations unchanged.
- Use preflight/warm-up, at least ten repetitions and rotated variants, including
  equivalent baseline/current controls. Benchmark runners remain sequential.
  Record medians, ranges and request/peak units, including negative experiments.
- Profiling hooks are selected at compile time; ordinary execution has no clocks,
  allocation counters or callback dispatch. Separately report counter-only and
  timed-probe overhead. Narrow operation times include instrumentation and do not
  constitute an exact decomposition of an uninstrumented parse. Recursive child
  parsing stays outside container-operation intervals.
- Distinguish logical requests inside an arena from backing capacity and process
  RSS. Bulk arena release need only return backing live bytes to zero; individual
  logical requests are reclaimed together.

## Verified slices

Each slice is verified and committed before starting the next. Before a feature
or fix commit, read the version with `zig build version`, keep major 0 and use
the pinned `zig build version -- set VERSION` command. Profiling features receive
a minor increment; behavior-preserving runtime fixes receive a patch increment.
Include every updated version marker. Write the complete commit message into a
temporary file, use `git commit -F`, then remove it with plain `rm`.

1. [x] Record this plan, link it from the completed report/project docs and retain
   the baseline CLI. Verify document links and the diff; commit the plan.
2. [x] Add current-builder profiling and a fresh baseline:
   - Expose internal compile-time observation points for token acquisition,
     array growth/non-growing append, duplicate checking, indexed insertion,
     object finalization and the bounded arena seed. Capture exclusive operation
     counts/logical requests and optional elapsed times without changing the
     public query API or ordinary allocator identity.
   - Compare the frozen 0.22.0 reference/control, production/current control,
     counter-only and timed instrumentation. Include null, small report, both
     scale fixtures, escaped/nested/long-number data, flat/nested arrays and
     wide objects. Report the instrumentation overhead explicitly.
   - Check output/order/spelling, malformed/duplicate diagnostics, observation
     coverage and allocation-failure cleanup. Run native Debug build/tests,
     publish raw evidence and record a candidate-specific gate before coding
     the runtime optimization. Commit instrumentation and baseline first.
3. [ ] Optimize the largest actionable parser construction cost:
   - Evaluate a bounded allocation/construction change supported by the baseline,
     avoiding an extra full token pass unless its measured total cost wins.
   - Default gate: at least 10% lower median full-parser time on both large
     fixtures, beyond reference/control variation, with no unexplained backing
     peak increase. A memory-focused candidate may instead require at least 20%
     lower logical container traffic and backing peak on its targeted fixture,
     without a material time regression; record that choice before the change.
   - Investigate other-case regressions exceeding both 10% and 0.05 ms, or any
     unexplained peak increase. Exercise size/capacity boundaries, empty and
     nested containers, errors/locations, escaped duplicates, caller-buffer
     reuse, retained values and failures in each changed allocation path.
   - Retain only a passing optimization. Preserve rejected patches/results and
     give a bounded negative conclusion if no candidate passes. Commit the
     verified runtime slice separately from its measurement support.
4. [ ] Perform the structural-materialization follow-up:
   - Establish matched controls for known-size `keys`/`map` output storage and
     stable structural sorting; distinguish source creation from sorting.
     Keep component results checked against actual evaluator/public output.
   - Include repeated/all-distinct schemas, mixed values, ordered/unordered and
     reverse/partially ordered rows. Preserve full-pipeline measurements so
     component gains cannot hide parsing, validation or upstream costs.
   - Evaluate exact known-size reservation and a validated sorted-input shortcut
     separately. Gate allocation changes on at least 20% lower targeted logical
     request bytes without higher backing peaks; gate sort changes on at least
     20% lower targeted sort time beyond controls. Investigate full-query
     regressions exceeding both 10% and 0.5 ms and any unexplained peak increase.
   - Verify stable representatives, equivalent numeric spellings, Unicode keys,
     original field order, invalid exponent/depth rejection, diagnostics, retained
     collections and allocation failures. Record rejected candidates honestly.
     Commit verified instrumentation and each accepted runtime change separately.
5. [ ] Complete native Debug build/tests and the separate-package consumer.
   Run all 45 frozen corpus cases with five timing repetitions and repeat the
   parser/structural studies and matched public CLI comparisons. Preserve all
   30 selected observed translations and ten intentional probes. Publish raw
   evidence, measurements/limits and remaining costs; mark the plan complete and
   commit the final report. Remove temporary experiments/checkouts after keeping
   the required baseline artifacts and reproducible rejected patches.

## Completion

The report distinguishes direct measurements from instrumented experiments,
accepted runtime changes from rejected candidates, and measured workload gains
from general claims. All functional checks pass in the one routine build mode;
no workflow coverage is added by performance fixtures. A bounded investigation
with preserved negative evidence completes an experiment even when it does not
justify a runtime change.

## Implementation record

Planning: reviewed the builder, input boundary, key-array materialization,
structural sort, allocator meter and completed 0.22.0 evidence. The current
builder uses repeated array append and small-object buffering; `keys` and `map`
know their final output lengths but use growing-capacity reservation. The
structural sorter always enters stable block sort. These are hypotheses to
measure, not proof that any particular replacement is faster.

Slice 2, 0.23.0: the [builder baseline](../profiling/2026-11-11-builder-baseline.json)
has 576 checked samples: eight inputs, six rotated variants and twelve
repetitions. A frozen 0.22.0 builder provides reference/control; current/control
are ordinary parses. Counter-only and timed probes observe the same generic
production builder with a compile-time observer; the void specialization has no
probe calls/clocks/counters. Native Debug build and all 213 checks pass, including
operation coverage, logical-request attribution, malformed/decoded-duplicate
locations and failure cleanup. Original and current uninstrumented large-case
times/peaks agree within control variation after adding observation points.

Backend full-parser medians are 54.319/54.188 ms reference/control and
53.941/54.381 ms current/control, with the same 10,517,879-byte backing peak.
Counter-only takes 60.959 ms and timed probes 120.888 ms. The probe owner setup
is outside its timer, so tiny-input timing is not a matched startup comparison.
Narrow timings include substantial per-operation overhead and are not a CPU
budget for ordinary parsing. Token acquisition, duplicate checks and object
finalization are separately labeled; indexed insertion includes hashing/growth.

Backend array growth requests 4,705,792 logical bytes in 38 growth allocations,
versus 4,560,760 bytes in 30,002 object-storage allocations. The two large arrays
interleave child objects with storage growth, leaving old buffers in the arena.
Command arrays request 1,169,280 bytes; small argv arrays also have spare capacity.
The largest bounded allocation candidate is chunked array accumulation with a
small stack prefix and one exact final array, without another scanner pass.

Gate recorded before slice 3: use the memory-focused path. Require at least 50%
less backend logical array-request traffic and at least 20% lower full-parser
backing peak, with ordinary large-parser time no more than 5% above matched
reference/control medians. Investigate other-case regressions exceeding both 10%
and 0.05 ms and every unexplained peak increase. Cover flat/nested/wide/escaped
cases and capacity boundaries. Reject or adjust a candidate that fails these
gates; do not claim a CPU improvement from the narrow instrumented intervals.
