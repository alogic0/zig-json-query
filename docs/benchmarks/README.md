# Benchmark qualification

The Zig runner in `tools/bench.zig` reuses zig-test-support for bounded process
capture, deadlines, owned temporary workspaces, file IO and hashing. GNU time
reports child peak RSS; a monotonic clock measures wall time including process
supervision/capture. This is a local comparative measurement, not a general
performance or portability claim.

## Reproduce

```sh
zig build bench -Doptimize=ReleaseSafe -- \
  --rows 100000 --repeat 5 \
  --jq /usr/bin/jq --jq-version jq-1.7 \
  --jaq /absolute/path/to/jaq --jaq-version 'jaq 3.1.2' \
  --out docs/benchmarks/local.json
```

Version output must match exactly. Binary SHA-256s, input SHA-256s/lengths,
queries/flags, output SHA-256s/lengths, platform, compiler, optimization and every
timing/RSS sample are recorded. Omitting jaq records an explicit skipped entry.
The runner generates deterministic fixtures and does one reference warmup per
case, then rotates tool order between repetitions. Non-precision output
mismatches fail the run. Precision-case differences are retained as semantic
differences, excluded from equivalent-workload claims. A null RSS means the OS
reported zero/unavailable. No additional benchmark scripts are needed.

## 2026-11-09 evidence

[2026-11-09.json](2026-11-09.json) records five repetitions for three tools across
seven cases: startup, projection, filtering, regex, numeric precision, NDJSON,
and a larger document. Each regular fixture has 100,000 records (3,476,402 bytes
for the document); the larger document has 400,000 records (14,238,902 bytes).
NDJSON uses an incremental reduction in jq/jaq, not slurping. The precision
fixture has eight exact integers around 2^53. All measured outputs matched.

Host: AMD Ryzen 7 7840HS, x86_64 Linux 7.0.0-42-generic, GNU ABI; installed
Zig 0.17.0, ReleaseSafe. Tools: jq 1.7 and jaq 3.1.2, with exact binary hashes
in the report. jaq was absent from PATH and the portfolio inventory. Its
[official v3.1.2 release](https://github.com/01mf02/jaq/releases/tag/v3.1.2)
provided `jaq-x86_64-unknown-linux-gnu`; the downloaded binary matched the
published SHA-256
`df94e0ce3658897a5677958417347e1109f91f72b9f75b8fe8f028a70c90b766`.
It is cached locally at `.zig-cache/tools/jaq-3.1.2`, not included in the source
distribution. Re-acquire a verified binary if that cache is cleared.

The main measured bottleneck is NDJSON execution: per-record parsing/allocation
and session evaluation make this prototype slower than both comparators on the
count workload. Its retained memory stays small. Larger-document projection
benefits from lower measured memory use, but still parses the whole document.
These seven synthetic cases do not cover general jq compatibility, pathological
regexes, real-world distributions, sorting/grouping scale or cold filesystem
caches. Startup samples are particularly sensitive to process-runner overhead.
