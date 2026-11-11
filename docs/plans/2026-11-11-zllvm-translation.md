# z_llvm jq usage and jqz translations

Status: complete. jqz 0.28.0 translations are checked on retained compiler data,
with explicit gaps, preserved evidence and private-file cleanup.

## Scope

Inspect `/home/oleg/prog/z_llvm` and compiler session
`01a1c2a9-b739-7e13-b134-3167995ee5d1` in `~/.codex-llc`. Extract query usage
without executing historical command text. Try concrete jqz translations on
retained, actual compiler JSON and compare outputs/statuses against installed
jq 1.7. Preserve a useful translation catalog, checked evidence and explicit
unsupported semantics. No compiler build, compiler-source edit, language feature
or provider change is required for this audit.

The project checkout is initially clean. Its tracked validation tools are Zig;
most jq usage is ad hoc history or retained `.jq` scripts. A fixed, validated
history snapshot has SHA-256
`54ff8b1ba32f9de4ee62eee025eddf8f0e51ecce3b29a57d76fed0c40fe820c1`.
It yields 1,968 distinct completed-command records mentioning jq/jg, ending at
record 37,583; these are candidates, not a claimed invocation count. Current
retained validation directories contain 176 `.jq` files. The temporary raw
snapshot was removed with plain `rm`; extracted command text remains ignored
and will be removed after producing the query-only inventory.

## Steps

1. [x] Locate project guidance, session records, existing sanitized compiler
   provenance, query scripts and actual report inputs. Freeze the audit boundary
   and commit this plan before writing translation artifacts.
2. [x] Extract a conservative literal-query inventory with a Zig helper. Respect
   shell quoting and ignore heredoc bodies; never evaluate shell text, command
   substitutions, dynamic paths or query interpolation. Report extraction limits
   and preserve record references. Keep private commands and report payloads out
   of committed artifacts. Classify retained scripts separately from confirmed
   inline invocations.
3. [x] Write representative reusable jqz query files for real compiler jobs,
   including full original windows/fields where supported. Run jq and jqz with
   explicit argv and bounded process capture against existing inputs. Compare
   exact bytes or ordered JSON values with exact-decimal comparison, output
   cardinality and exit statuses. Include negative gates and counterexamples for
   unsupported features. Preserve hashes/counts, not private output payloads.
4. [x] Document verified translations, required invocation changes, genuine
   language/CLI gaps and practical priorities. Add focused Zig checks for any
   audit helper and sanitized cases that demonstrate the translated semantics.
   Validate native x86_64 Linux Debug only, preserve the original 45-case corpus
   and historical evidence, remove temporary private extraction files with plain
   `rm`, and commit verified slices. Leave the compiler checkout unchanged.

All new substantive helpers/checks are Zig and reuse pinned test-support and
numeric comparison helpers. Existing tools suffice; consult the existing Zig
inventory before requiring another tool. Audit artifacts add no jqz runtime
behavior, so the binary under comparison stays at 0.28.0. Any necessary runtime
fix/feature would require its own verified slice and the normal pinned version
workflow. Commit messages use a temporary file and `git commit -F`; remove the
message file after success with plain `rm`.

## Experiment verification

The conservative scanner recognizes 2,711 command-position invocations, all
named `jq`, with 1,225 distinct literal inline filters. There are 305 dynamic
contexts and 90 `-f` invocations with 22 distinct argument strings. It recognizes 215
`--slurpfile` uses and eleven `--rawfile` uses. These are bounded lexical counts,
not an exhaustive shell trace; original command bodies remain private.

The 30-filter translation manifest matches 1,148 recognized uses. On retained
inputs, 62 differential checks cover 27 filters: 56 pass across 25 equivalent
filters, and six checks demonstrate two reviewed differences (joined raw output
and exact-decimal duration calculations). Three further filters have no directly
resolvable retained input and remain unverified. Actual inputs are hashed before
and after each pair; outputs are represented by sizes/hashes only. Query files
are checked against the manifest before execution. No historical shell command
is executed and no compiler workload is launched.

Eight fresh Zig audit checks pass, including independent jq expectations for
truthiness, empty completion, multiple results, negative `-e` status, null group
keys, tie ordering, the NUL protocol difference and timestamp precision beyond
`2^53`. Native Debug project build
and tests also pass, reusing unchanged cached results. The extraction/checking
helper and its shared mapping/fixture data form one verified experiment slice;
the final interpretation and preserved result files are a separate slice.

The experiment slice is `5cc4fbe5fb848ee4e17936673e3b5025ff265dc7`, followed by
timestamp-precision regression `27cbc34`. The
[completed report](../qualification/zllvm-usage-2026-11-11.md) links the
[query-only inventory](../qualification/2026-11-11-zllvm-inventory.json) and
[live check results](../qualification/2026-11-11-zllvm-translations.json), explains
limits and reproduction, and ranks joined raw output/file bindings/local dynamic
maps from actual usage. Both generated results are preserved byte-identically;
helper/manifest/binary hashes match. The fixed-boundary extraction is independently
reproduced. Private command/invocation extracts are removed with plain `rm`.
The compiler checkout stays clean and production jqz sources/version remain
unchanged. No further work remains in this audit plan; the identified feature
requirements are recommendations for separately authorized implementation.
