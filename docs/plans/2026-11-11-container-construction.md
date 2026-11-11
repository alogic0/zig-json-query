# Container construction and structural materialization

Status: completed on 2026-11-11 in jqz 0.26.2; authorized on 2026-11-11.

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
3. [x] Optimize the largest actionable parser construction cost:
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
4. [x] Perform the structural-materialization follow-up:
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
5. [x] Complete native Debug build/tests and the separate-package consumer.
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

First slice-3 candidate rejected: [arena chunks](../profiling/2026-11-11-builder-chunked-rejected.json)
reduce backend logical array traffic from 4,705,792 to 2,267,840 bytes (52%), but
the backing peak is 8,520,779 versus 10,517,879 bytes (19% lower), missing the
predeclared 20% gate. Flat scalar arrays can grow contiguously without child
allocations; always retaining chunks plus a final copy wastes that advantage.
Equivalent reference/control peaks there also vary with remapping, so raw peaks
and ranges are retained rather than choosing the favorable control. The
[rejected patch](../profiling/experiments/builder-chunked.patch) applies to
`ef4fe65`; the main builder has been restored to that committed implementation.

Next bounded candidate: buffer a small prefix, then use a temporary array outside
the parsed arena for arrays whose prefix contains allocating children. Its growth
can release old buffers; copy once into final owned arena storage and free the
temporary array on success/failure. Large nonallocating scalar prefixes can keep
ordinary arena-backed growth without a final duplicate. Attribute temporary
requests explicitly alongside logical arena requests before evaluating the
unchanged memory gate; moving requests between owners is not a traffic reduction.

Temporary-owner instrumentation, 0.24.0: a small explicit source adapter carries
the caller allocator through the standard parsed-arena owner; it does not infer
an allocator from Scanner internals. Production construction is still unchanged.
The [576-sample baseline](../profiling/2026-11-11-builder-temporary-baseline.json)
separates arena logical requests, temporary/scanner requests and backing totals.
All temporary live counts return to zero. Reference/current parser medians are
24.156/24.408 ms for commands and 50.797/50.796 ms for backend, with identical
backing peaks. Native Debug build and all 213 checks pass. The unchanged candidate
gate applies to combined arena-plus-temporary array traffic, not arena traffic
alone. The explicit bridge and accounting are committed before the next runtime
candidate.

Slice 3, 0.24.1: arrays buffer sixteen values on the stack. Allocating children
in that prefix or the first spill item select temporary chunks, growing from
sixteen to at most 1,024 values per chunk, followed by one exact arena-owned array. All chunks are
freed on success/failure. Otherwise arrays retain ordinary arena growth after
the stack prefix; late allocating children remain correct and use that selected
path. Small arrays need one exact final allocation.

The [720-sample comparison](../profiling/2026-11-11-builder-optimized.json) passes
the memory gate: backend array traffic is 1,120,000 arena bytes plus 1,146,048
temporary bytes, 2,266,048 total versus 4,705,792 (52% less). Backing peak is
8,223,471 versus 10,517,879 bytes (22% lower). Command peak is 3,868,573 versus
4,223,391 bytes. Backend ordinary medians are 48.956/49.515 ms current/control
versus 48.482/48.425 ms reference/control, within the 5% time bound. This is a
memory improvement, not a claim of a faster backend parser.

Empty-container and late-allocating fixtures extend the comparison to ten cases.
Boundary, logical-arena/temporary allocation-failure and retained-buffer tests
pass: 216 project checks, eight separate-consumer checks and all 45 corpus cases.
The [24-repetition follow-up](../profiling/2026-11-11-builder-optimized-followup.json)
confirms the large memory result. The small escaped case has current/control
medians 0.425/0.467 ms versus reference/control 0.435/0.385 ms; it does not support
a uniform timing conclusion. Temporary live bytes return to zero; its 1,057-byte
temporary peak and arena remap variation explain the small overlapping capacity
ranges. Improve predecessor balance in the measurement order before final timing
claims, and preserve these raw observations rather than selecting a favorable
control. The primary memory gates remain satisfied.

Measurement correction, 0.24.2: rotating a fixed sequence balances positions but
retains the same neighbors. The builder now uses six-variant sequences that also
balance every directed predecessor pair; a focused schedule test verifies both
properties. The [720-sample balanced run](../profiling/2026-11-11-builder-balanced.json)
has escaped-case medians 0.392/0.392 ms current/control versus 0.366/0.373 ms
reference/control, below the 0.05 ms investigation threshold. Its small capacity
increase is 96–226 bytes against reference/control, within the independently
accounted temporary peak. The large backing peaks and combined traffic gate are
unchanged. Backend ordinary medians are 47.526/47.233 versus 47.743/47.535 ms;
commands 22.685/23.091 versus 22.684/22.839 ms. Native Debug build and all 217
checks pass. This correction is a separate profiling fix, not another parser
runtime optimization; earlier raw order/results remain intact.

Slice 4 instrumentation, 0.25.0: the
[collections baseline](../profiling/2026-11-11-collections-baseline.json) records
2,688 checked intervals across eight distributions and twelve balanced
repetitions. Reference/control models freeze 0.22.0 reservation and stable block
sort; current/control use extracted production helpers with unchanged behavior.
Separate actual source/full evaluator intervals expose AST/path costs omitted
from the models. Every source/result matches public execution bytes, logical
traffic is distinct from backing capacity and cleanup reaches zero.

Repeated-schema source requests 3,640,112 logical bytes in 10,001 allocations
for both models and the actual evaluator. Model source medians are 5.726/5.759 ms
reference/control; actual source is 10.205 ms and full query 20.240 ms. These
different timer boundaries are not interchangeable. Sort is 6.805/6.828 ms on
repeated schemas, 1.029/1.025 ms sorted, 1.547/1.555 ms reverse and 1.027/1.028 ms
with a late inversion. The allocation/sort gates from slice 4 remain unchanged.
First evaluate exact reservation for `keys` and `map`, then evaluate the sort
shortcut separately. Native Debug build and all 219 checks pass. Matched public
CLI support now also includes backend key-array materialization/schema uniqueness
and balances large-process predecessor pairs before runtime changes.

Known-size storage, 0.25.1: `keys` and `map` now reserve their exact final value
count through the shared helper. The [matched storage comparison](../profiling/2026-11-11-collections-storage.json)
has 2,688 checked intervals. Repeated-schema source requests fall from 3,640,112
to 1,680,000 logical bytes (54% less), and source backing peak from 6,002,172 to
2,109,224 bytes. Later row allocation grows a fresh arena region: full pipeline
peak is 5,687,684 versus 6,002,172 bytes, a smaller 5% reduction rather than the
source-only 65%. All-distinct full peak falls from 771,094 to 575,962 bytes;
nonmaterializing distributions keep their peaks. The allocation gate passes.
Reference/current model source medians are 6.057/4.798 ms; actual source/full
medians are 9.111/18.934 ms and remain separately labeled.

Native Debug build and all 220 checks pass. A constrained allocator proves
Unicode object-key and identity-map results fit exactly their required value
storage, including empty outputs. Existing path/type, retention, budget and
allocation-failure checks remain unchanged and pass. Sorting is still the
original stable block sorter; its candidate is a separate runtime slice.

Sort controls, 0.26.0: the
[3,072-interval baseline](../profiling/2026-11-11-collections-sort-baseline.json)
adds paired whole-pipeline sorter controls with actual source evaluation and
current storage on both sides. Only the sorter differs; ordinary full evaluator
intervals remain separate because successful outer `unique` path setup is omitted
from the controls. Sorted/reverse/late-inversion inputs now contain 10,000 values
and record new hashes/cardinalities; earlier 1,024-value observations remain
historical. Native Debug build and all 220 checks pass.

Unchanged full-sort reference/current medians are 19.315/19.209 ms on repeated
schemas, 21.200/21.256 ms sorted, 30.999/30.933 ms reverse and 21.204/21.088 ms
with a late inversion. Ordinary repeated-schema full evaluation is 19.585 ms.
This establishes the full-pipeline regression control before evaluating a
validated sorted-input shortcut. The predeclared 20% targeted sort-time gate
and 10% plus 0.5 ms full-pipeline regression investigation gate still apply.

Sorted-input guard rejected: the
[3,072-interval experiment](../profiling/2026-11-11-sort-guard-rejected.json)
reduces repeated-schema sort from 7.201 to 1.135 ms, but a late inversion costs
25.634 ms full pipeline versus 22.062 ms reference (16% and 3.572 ms higher).
The extra prefix scan fails the full-query gate. The
[rejected patch](../profiling/experiments/sort-guard.patch) applies to `7d1c521`;
the production sorter has been restored before continuing.

Comparator reference fix, 0.26.1: the
[3,072-interval baseline](../profiling/2026-11-11-comparison-baseline.json)
freezes the 0.22.0 comparator as well as stable block sort. Production comparison
is unchanged; all 220 native Debug checks pass. Reference/current repeated sort
medians are 7.022/6.638 ms, full-sort 19.107/19.444 ms; late-inversion full-sort
is 22.051/21.838 ms. The small implementation/context difference is recorded
before the next candidate, with equivalent paired controls.

Next bounded sort candidate: keep stable block sort and avoid redundant type-rank
mapping when two validated values already have the same union tag. Cross-type
ordering keeps explicit JSON ranks; numeric, container and stable-equality
semantics remain unchanged. This introduces no extra row scan. Apply the same
20% targeted sort-time gate and full-pipeline time/peak regression gates, using
the frozen comparator for the reference sorter. Record this candidate before
changing production comparison.

Same-tag rank bypass rejected: the
[3,072-interval run](../profiling/2026-11-11-same-tag-rejected.json) has repeated
sort medians 6.807/7.341 ms reference/control and 6.624/6.818 ms current/control.
This does not meet the predeclared 20% target. The
[patch](../profiling/experiments/same-tag-comparison.patch) applies to `0423521`;
production comparison is restored. Avoiding rank mapping alone is not sufficient.

Next bounded comparator candidate: compare primitive container children inline
instead of recursively dispatching the complete JSON comparator for each string,
number, boolean or null. Nested containers and cross-type children keep the
existing recursive comparator. Keep stable block sort and the same 20% sort-time,
full-pipeline regression and memory gates. No extra pass or comparison-key storage
is introduced. This is the last bounded comparator experiment in this plan;
preserve a negative conclusion if it does not justify a runtime change.

Primitive-child comparison rejected: the
[3,072-interval experiment](../profiling/2026-11-11-primitive-child-rejected.json)
has repeated sort medians 7.588/6.935 ms reference/control and 6.380/6.167 ms
current/control, below the 20% target for both pairings. Full-sort medians are
19.634/18.268 ms reference/current, while the ordinary full evaluator is
20.413 ms, so no uniform complete-query speedup follows. The
[patch](../profiling/experiments/primitive-child-comparison.patch) applies to
`f561c63`; production comparison has been restored. This completes the bounded
sort investigation with three rejected candidates. Stable block sort and the
original comparator remain; exact materialization storage is the accepted
structural change. No new sort algorithm, row pass or cached key representation
is retained without meeting the recorded gates.

Final empty-container audit: the initial final
[720-sample builder run](../profiling/2026-11-11-builder-empty-check.json) at
0.26.1 has empty-container medians 2.409/2.452 ms current/control versus
2.287/2.209 ms reference/control. The control pairing exceeds the 10% and
0.05 ms investigation threshold. Inspection finds unnecessary finalization and
cleanup function calls on empty arrays and cleanup calls on every array without
chunks. Skip those calls while preserving the existing scoped cleanup whenever
chunks exist; do not alter storage selection or parsing. Repeat balanced builder
measurements and the final checks before accepting this focused follow-up fix.

Empty-container fix, 0.26.2: empty arrays return without finalization, and arrays
without temporary chunks skip the cleanup helper. Existing ownership/error paths
and storage decisions are unchanged. Native Debug build and all 220 checks pass.
The [1,440-sample balanced run](../profiling/2026-11-11-builder-final.json) has
empty-container medians 2.476/2.451 ms current/control versus 2.398/2.363 ms
reference/control, below the investigation gate. Large-parser medians remain
within 5% of paired references (commands 26.154/25.579 versus 25.314/25.426 ms;
backend 52.643/52.169 versus 51.750/51.554 ms). The 22% backing-peak and 52%
combined array-traffic reductions are unchanged. Escaped-case medians differ by
0.042/0.050 ms (the latter is 0.049857 ms), below the absolute investigation
threshold; broad ranges are retained and no uniform parser time gain is claimed.

Slice 5, final 0.26.2 verification: native Debug build and all 220 project checks
execute and pass; eight separate-package consumer checks pass. The
[full qualification](../qualification/2026-11-11-container-construction.json)
preserves all 45 frozen cases, 30/30 selected observed translations and ten probes,
with RSS available for all 340 timed samples. Final runs record 490 ordinary
phase intervals plus ten launches, 1,440 builder samples, 490 original-parser
experiments, 3,072 collection intervals, 800 original structural intervals and
276 invocation samples. All outputs, source/tool fingerprints and cleanup checks
pass. Corpus and historical raw evidence remain unchanged.

The [completed report](../profiling/container-construction-2026-11-11.md) records
the accepted 52% combined backend array-traffic / 22% parser-peak reductions and
54% repeated-schema source-traffic reduction. Matched 0.22.0/current CLI ranges
overlap, so no general latency gain is claimed. Four rejected patches apply to
their recorded bases; stable block sort and the original comparator remain.
No extra tools or build modes were needed. Temporary experiments were removed,
the ignored 0.22.0 binary is retained, and links/diff checks pass. The final
evidence/documentation commit keeps version 0.26.2.
