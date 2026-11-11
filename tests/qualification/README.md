# Practical workflow corpus

`cases.json` freezes queries, flags, fixture aliases, expected JSON values/raw
bytes and exit codes. `provenance.json` preserves original jq expressions and
source session/record references. Only queries and option names were exported;
logged shell commands, argument values and private artifact paths are excluded.
No private session storage is needed to run the corpus.

The sample is deliberately selected, not an exhaustive or frequency-weighted
sample of every invocation. It contains 30 observed workflow cases (all translated),
3 isolated components, 10 contract probes and 2 generated scale cases. Scalar
serialization/sizing, immutable configuration edits and structural uniqueness
close the last three gaps. Grouping and totals cover both embedded-summary projections;
the component checks remain outside observed coverage. The argument-only
construction case uses `-n` for both tools, with identical bindings and no input
files. Its original query, expected output and observed case identity are unchanged.
It is now eligible for measurement alongside the other 34 equivalent cases,
with zero invocation adaptations. Historical reports retain the earlier
null-fixture workaround and its measurement exclusion.

## How fixtures were reconstructed

Compiler artifacts were available at qualification time. Their current structure
was inspected without copying paths, argv contents, source text, logs or IDs.
The command array had 2,837 entries with argv/cwd/returncode/wall-time fields;
comparison artifacts had 9 differences and numeric `changed_moves`. Sample
reports had arrays of time/available-memory/AIR-count objects, while the timing
measurements used a numeric `samples` count and an elapsed-nanosecond array.
These are current artifact observations, not reconstructed historical counts
at each command's execution time. The small fixtures reduce cardinalities and
replace all values with deterministic generic data.

Most selected backend inputs were temporary files and no longer existed.
Captured JSON projections at backend records 285, 395, 518, 20697 and 27383
establish summary/fixture/screenshot/HTTP shapes. The last projection shows
numeric HTTP counts and an object result/last HTTP record. Inputs were rebuilt
from these projections and the recorded queries, not presented as exact redacted
copies of unavailable originals. The backend configuration input and source
qualification artifacts were also available for structural inspection.

Fixtures retain only schema needed by the selected jobs, optional/null cases,
both passed/failed states, stable IDs/paths/hashes invented for this corpus,
numeric timing values and non-sorted status order. No source/customer payload
is copied. `duplicate.json` is deliberately invalid under jqz's unique-key rule.
The scale cases share a Zig generator with the phase profiler: one matches the inspected command count
with sanitized repeated records, the other creates 10,000 HTTP/fixture records.
They do not claim to preserve original payload sizes or value distributions.

## Checks and interpretation

Run `zig build qualify -- --repeat 5 --out .zig-cache/qualification/local.json`.
The runner requires the installed jq 1.7 and GNU time, records their hashes,
preflights every reference and candidate against independent frozen expectations,
then measures only equivalent cases. It fails on unexpected behavior or changes
to inputs, source fingerprints or tool binaries during measurement.

Objects compare independently of key order; arrays/result sequences keep order.
Numbers compare exactly as decimals, so `1.5` equals `1.500000` without erasing
large-integer differences. Raw output is byte-exact. Every probe records a
deliberate difference: false defaults, missing fields, group ordering, arithmetic
precision, duplicate keys, explicit rounding, empty-array totals, UTF-8 sizing,
missing-path deletion and error exit codes. No selected observed case is currently
unsupported. The runner does not execute query strings through a shell.

The sorted-configuration component compares compact output byte-for-byte,
including nested key ordering, rather than treating JSON object order as
irrelevant. The reference uses jq `-c -S`; jqz is compact by default with `-S`.

Equivalence applies to the selected fixtures, not every input accepted by jq.
In particular `sum([])` is `0`, whereas jq `[] | add` is null, and jqz sums require
checked i128 integers. The empty-total probe checks this difference separately.
The grouped-summary projection explicitly sorts its results to match jq; scalar
grouping itself keeps the stream stage's first-seen order.
The sample-size fixture is ASCII; a separate Unicode fixture/probe distinguishes
UTF-8 bytes from scalar counts. Path edits require existing targets, and the
missing-deletion probe records the difference from jq's ignored absent field.
