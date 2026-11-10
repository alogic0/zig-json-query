# Follow-up implementation

The user authorized the review fixes and all queued milestones on 2026-11-09.
This extends the completed stream-runtime plan.

Status: implemented and qualified locally on 2026-11-09. See the
[qualification report](../validation-2026-11-09.md) for executed checks, target
limits and benchmark evidence. No publication or upstream provider changes.

## Contracts

- Count container levels consistently: at most 128 arrays/objects, including
  empty containers. Emitted JSON must satisfy the same limit as parsed input.
- `-r` / `--raw-output` writes strings without JSON quoting, followed by a newline.
  Other values retain JSON serialization. Embedded string newlines remain literal.
- `-f FILE` / `--from-file FILE` selects the query file; the sole positional
  argument then names the input. Otherwise positions are QUERY and optional FILE.
  One query source is allowed. `-f -` reads the query from stdin and requires an
  explicit non-stdin input file. `--` ends options. Query files share the 64 KiB
  query limit. Errors identify the query/input file, syntax line/column and a
  bounded source excerpt; evaluation errors include a JSON path where known.
- `+`, `-`, `*`, `/`, `%`, unary `-`, and stream `sum` operate on exact signed
  128-bit integers. Integral decimal/exponent spellings (e.g. `1.0`, `1e3`) are
  accepted; fractions, out-of-range operands and overflow are errors. Division
  must be exact: no rounding or truncation. Remainder has the dividend's sign.
  Empty `sum` emits `0`. Existing arbitrary decimal comparison/passthrough stays.
- `sort` and `sort_by(expr)` buffer one stream and emit individual records in
  ascending stable order at completion. Keys must all be numbers or all strings;
  comparisons retain the existing exact decimal / UTF-8 byte-order contracts.
  Empty input emits nothing. Missing keys and mixed/unsupported key types error.
- `group_by(expr)` emits one array per distinct key in first-seen key order;
  each array preserves input order. Keys use structural JSON equality, including
  numeric normalization and object key-order independence. Empty input emits
  nothing. Missing keys error. The initial grouping algorithm is quadratic.
- All retaining stages share `max_collect_bytes` (64 MiB by default), including
  owned keys, container capacity and grouping scratch. No disk spilling; budget
  failures poison the session and identify the responsible stage. Early-stop,
  completion, ownership and failure contracts apply to new stages too.
- Release work pins source archives and records provenance/checksums; fuzzes
  parser/evaluator with bounded inputs; adds a Zig benchmark harness for pinned
  jq/jaq comparisons with output equivalence, wall time and peak RSS. Missing
  tools are reported explicitly. Release qualification targets x86_64 Linux.
  Additional architectures require a concrete deployment need before being
  added to the plan. No performance or target support claim without evidence.

## Work

- [x] Depth and file-error regressions/fixes.
- [x] CLI flags, query files, syntax locations and JSON paths.
- [x] Arithmetic and sum, including boundary/failure tests.
- [x] Stable sorting and structural grouping with shared-budget tests.
- [x] Parser/evaluator fuzz targets and generated semantic checks.
- [x] Immutable dependencies and standalone package validation.
- [x] Benchmark harness/results and x86_64 Linux qualification.
- [x] Update README, DESIGN and validation evidence.

The benchmark matrix includes pinned jq 1.7 and jaq 3.1.2, exact executable
hashes, seven workloads and five repetitions (105 samples), with output equality
checked before interpreting timings. jaq was initially absent; the official
binary was fetched to the ignored tool cache and its published checksum verified.
Native GNU and musl Linux acceptance is executed on x86_64. ARM qualification
is outside the current release scope; QEMU is not a project prerequisite.
