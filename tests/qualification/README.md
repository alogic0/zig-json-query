# Practical workflow corpus

`cases.json` freezes queries, flags, fixture aliases, expected JSON values/raw
bytes and exit codes. `provenance.json` preserves original jq expressions and
source session/record references. Only queries and option names were exported;
logged shell commands, argument values and private artifact paths are excluded.
No private session storage is needed to run the corpus.

The sample is deliberately selected, not an exhaustive or frequency-weighted
sample of every invocation. It contains 30 observed workflow cases (25 translated,
5 unsupported), 2 isolated components, 7 contract probes and 2 generated scale
cases. The component checks do not turn the unsupported full grouped summary
into a passing translation. The argument-only construction case needs a null
fixture because jqz has no `-n`; this invocation adaptation is counted explicitly
and excluded from timing comparisons.

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
The scale cases are generated in Zig: one matches the inspected command count
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
precision, duplicate keys, explicit rounding and error exit codes. Unsupported
jobs have checked jq oracles but no passing jqz translation; their reasons remain
in the manifest. The runner does not execute query strings through a shell.
