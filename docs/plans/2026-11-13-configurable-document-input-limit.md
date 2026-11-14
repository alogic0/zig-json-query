# Configurable JSON document input limit

Date: 2026-11-13
Status: implemented and qualified in 0.36.0 through the jqz/zigrep workflow.

The compiler validation workflow needs to project a few fields from a retained
113,221,765-byte ELF metadata report. Installed jqz 0.35.0 rejects it with exit 2:
`cannot read JSON document (limit 64 MiB): StreamTooLong`. This is the documented
default limit, but the CLI has no way to deliberately raise that input budget.
The retained/slurp budget options do not control ordinary document input.

The real private workload is
`/home/oleg/prog/z_llvm-validation-qualified-behavior-v1461/local-state/isolated-validations-qualified-behavior-v1461/review-compiler-blockaddress-metadata-v1520/report.json`.
Its captured invocation and result are beside that directory in
`jqz-large-metadata-reproducer-v1525-run.json` and `.log`.
Do not commit this report or other project-private data as a fixture.

Implement `--max-document-bytes N` as an explicit positive byte limit for
ordinary JSON document files and stdin. Retain the current 67,108,864-byte
default. Reject missing, zero, malformed and overflowing values with the
ordinary CLI error status. Keep NDJSON line, binding, query, retained-stage and
slurp budgets separate, and document what the new option does and does not
bound. Do not introduce an unlimited setting or silently raise defaults.

Acceptance:

1. Native regression coverage proves the default, an explicitly raised limit,
   exact boundary behavior, invalid arguments and complete JSON validation.
   Use small configurable limits in routine tests where possible; retain a
   bounded synthetic document above 64 MiB for CLI qualification if needed.
2. Run the pinned Zig checks and tests in Debug and ReleaseFast; qualify the
   public package consumer when its interface is affected.
3. Bump the appropriate release version, commit verified changes separately,
   and install the final ReleaseFast binary atomically in `~/bin` after
   comparing installed/build bytes and recording hashes.
4. Through the installed binary, the real report still fails at the default
   and succeeds with `--max-document-bytes 134217728`, producing passed status,
   relocation count and exactly twelve source-proven block-address entries.
5. Retain commands, source revision, statuses, timing and installation receipt.
   Keep all z_llvm source, caches, artifacts, locks and holds untouched.

## Resolution

The CLI accepts a positive decimal `--max-document-bytes N` limit for each
ordinary file or stdin document. It passes the same bound to the byte reader
and strict parser, reports the configured byte limit on read failures, and
retains the 67,108,864-byte default. NDJSON and null-input mode do not use this
ordinary-document override. Binding, query, embedded-JSON, retained-stage and
owned-slurp admission remain separate.

Library sessions expose the positive `StreamOptions.max_document_bytes` field;
zero is rejected with `InvalidOptions`. Existing `Program.run` and
`Slurp.append` retain the default. `Slurp.appendWithDocumentLimit` admits an
individual source with an explicit limit while preserving the collector's
owned-allocation budget. `feedSlurp` consumes the already validated array.

Five library and six CLI regressions cover defaults, exact boundaries,
per-input limits, malformed options, Unicode byte sizes, full JSON validation,
nesting, failed-session state, NDJSON separation, bindings, query sources and
retained/slurp budgets. A new separate-package consumer regression covers the
public configuration and slurp method. Native x86_64 Linux Debug and the
explicitly requested ReleaseFast each pass 292/292 tests; the public consumer
passes 13/13 in each mode. Formatting and version-consistency checks pass.

The retained 113,221,765-byte report still fails at the default with status 2.
The ReleaseFast candidate succeeds with `--max-document-bytes 134217728`,
producing the exact requested three-field projection and twelve source-proven
block-address entries. Input identity, outputs, statuses, timings, peak RSS,
source revision and installation receipts are kept privately under
`local-state/validations/document-input-limit-20261113/` in this repository.
No compiler source, cache, artifact, lock or hold is modified.
