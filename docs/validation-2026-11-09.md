# Qualification on 2026-11-09

Installed compiler: Zig 0.17.0, Linux x86_64. Changes implement the contracts in
[the follow-up plan](plans/2026-11-09-followups.md). The original stream checkpoint
remains in [its plan](plans/2026-11-09-stream-runtime.md).

The release target is x86_64 Linux. Required validation covers that architecture;
additional architectures will be planned only for a concrete deployment need.

The runtime, fuzz and benchmark checkpoint below records version 0.1.0.
The later version-workflow and binary-name checkpoints are recorded at the end.

## Functional and ownership checks

| Command / check | Result |
| --- | --- |
| `zig build test --summary all` | 69/69: 54 language/library, 15 native CLI |
| `zig build test -Doptimize=ReleaseSafe --summary all` | 69/69 |
| `zig build test -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --summary all` | 69/69, including execution of the musl CLI |
| `cd tests/package && zig build test -Doptimize=ReleaseSafe --summary all` | Separate package consumer: 1/1 |
| `zig fmt --check build.zig build.zig.zon src tests tools` | Passed |
| Inventory's zig-source-audit over src/tests/tools | No syntax errors, local unresolved imports or cycles |
| `cd vendor && sha256sum -c SHA256SUMS` | Both pinned source archives match |
| `zig build dist` | Standalone source archive installed under zig-out/dist |
| Rebuild unchanged dist and compare SHA-256 | Identical archive bytes |
| Extract dist outside the portfolio, with empty local/global caches; run tests | 69/69 in Debug and ReleaseSafe |
| Extracted dist's separate tests/package consumer | 1/1 |

An optional `aarch64-linux` cross-compilation also succeeded without runtime
testing. This is historical evidence of an extra check, outside the release
requirements. It creates no ARM qualification requirement.

Depth regressions cover 128 nested empty arrays and objects, collection wrapping,
comparison, and accepted output that can be parsed again. CLI tests cover file
paths in errors, byte syntax positions in multiline JSON/NDJSON, query files,
stdin/query-source precedence, oversized query files, raw strings/nonstrings and
new stages across records. JSONPath tests distinguish missing input fields from
constructed/buffered outputs whose original input path is unknown.

Arithmetic tests cover exact integral decimal/exponent normalization, i128
endpoints, overflow, fractional/type rejection, exact/inexact division, zero
divisors, signed remainder and empty-stream sum. Sorting/grouping tests cover
stable numeric ties, exact large IDs, Unicode byte order, structural key
equality, first-seen groups, reusable input buffers, early-stop chains, shared
budget handoff and writer failures. Fault injection visits every allocation in
a sorting/grouping/arithmetic/downstream-collection scenario and checks cleanup.

Generated deterministic checks exercise 2,500 aggregate pipelines, 2,500 decimal
comparisons, 1,000 arithmetic cases and 100 sorting/grouping batches against
independent reference models. These are included in the ordinary test suite.

## Fuzz qualification

```sh
zig build fuzz -Dfuzz-target='fuzz parser' --fuzz=10000 --summary all --test-timeout 45s
zig build fuzz -Dfuzz-target='fuzz evaluator' --fuzz=10000 --summary all --test-timeout 45s
```

Both passed on the final runtime: parser report 10,662 runs, evaluator report
10,462 runs. Earlier iterations also completed 21,410 parser runs and 10,463
evaluator runs. Counters are fuzzer-reported and accumulate when caches are
preserved; this is bounded smoke qualification, not exhaustive proof. Query and
input fuzz buffers are capped at 512 bytes; output and retained allocations are
bounded. Parser fuzzing checks rejection diagnostics; evaluator fuzzing checks
session poisoning, cleanup, successful JSON output and the depth contract.

## Performance and tooling

[Benchmark evidence](benchmarks/README.md) describes the Zig runner and the
[105-sample report](benchmarks/2026-11-09.json). It pins jq 1.7 and jaq 3.1.2 by
version and binary hash, records equivalent queries/fixtures, checks output,
and reports elapsed wall time plus GNU time's child peak RSS. All outputs in
this matrix matched. The NDJSON count workload is slower than both comparators;
no general performance advantage is claimed.

The portfolio inventory supplied regex, test-support/process, and source-audit.
New implementation/tooling is Zig. jaq was missing from PATH and the inventory;
its official binary was downloaded into the ignored cache and its published
SHA-256 verified. QEMU is not a build, test or release prerequisite for the
x86_64 Linux target. No external service, CI run, publication or additional
operating-system support is implied.

## Distribution

The source archive ships the pinned regex/test-support archives, their existing
licenses/notices, all project sources, the separate package caller, examples,
plans, benchmark tooling and evidence. It excludes .zig-cache, zig-pkg and
zig-out; GNU tar normalizes order, timestamps, ownership and permissions.
Dependency hashes/provenance are in [vendor/README.md](../vendor/README.md).
The CLI still enforces its documented input/query/depth limits. Retaining stages
share a 64 MiB budget; grouping is initially quadratic and disk spilling remains
an explicit unsupported policy. Incremental parsing within a document, broader
decimal arithmetic and general jq compatibility remain separate future work.

## Shared version workflow: 0.2.0

The pinned `zig-package-version` 0.1.0 source archive at revision
`3b35ef146e0308b9aa0f61f27e95ae8c7f143a15` supplies the version CLI and library.
This project supplies `tools/versions.json`; no synchronization engine is copied
or reimplemented. The shared command performed the actual 0.1.0 -> 0.2.0 minor
bump, preserving major version 0 and all dependency and historical evidence pins.

| Check | Result |
| --- | --- |
| `zig build version` before the bump | `0.1.0`; all five markers synchronized |
| `zig build version -- set 0.2.0` | Updated four files / five marked locations |
| `zig build version` after the bump | `0.2.0` |
| `zig build test --summary all` | 73/73: 54 language/library, 15 CLI, 4 version integration |
| `zig build test -Doptimize=ReleaseSafe --summary all` | 73/73 |
| `zig build test-package-version --summary all` | 4/4 |
| Version benchmark smoke: 20 rows, one repetition, ReleaseSafe | Expected CLI version `0.2.0`; outputs match |
| `zig build dist` | Created `zig-json-query-0.2.0.tar.gz`, including the version configuration and pinned tool |
| Extracted 0.2.0 archive, empty local/global caches: `zig build version` | `0.2.0`; no sibling checkout required |
| Extracted archive: `zig build test-package-version --summary all` | 4/4 |

Version tests operate on disposable copies of the actual configured project
files. They exercise get/set, both archive names, mismatch reporting and repair,
invalid target rejection, and late preflight failure with unchanged file hashes.
Dependency version pins and a separate historical-version fixture remain intact.
The existing runtime/benchmark evidence above remains a 0.1.0 checkpoint rather
than being rewritten to claim new measurements.

## Short binary name: 0.3.0

The primary executable is `jqz`. Builds also install `json-query` as a
compatibility command; the repository and source archives retain the
`zig-json-query` name. Help, version output, option diagnostics, examples and
benchmark tool labels now use `jqz`. The version configuration follows the
renamed benchmark marker; the shared updater performed the 0.2.0 -> 0.3.0 bump.

Native Debug and ReleaseSafe test suites pass 73/73 tests. Installed `jqz`
reports `jqz 0.3.0`; its help uses the short name. The compatibility command
executed the example age sum successfully (`71`). A ReleaseSafe benchmark smoke
run checks the new label/version and equivalent outputs. Historical benchmark
records keep the executable name and version actually measured.
