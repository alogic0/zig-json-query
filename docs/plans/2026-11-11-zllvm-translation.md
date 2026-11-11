# z_llvm jq usage and jqz translations

Status: authorized audit and translation work, using jqz 0.28.0.

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
2. [ ] Extract a conservative literal-query inventory with a Zig helper. Respect
   shell quoting and ignore heredoc bodies; never evaluate shell text, command
   substitutions, dynamic paths or query interpolation. Report extraction limits
   and preserve record references. Keep private commands and report payloads out
   of committed artifacts. Classify retained scripts separately from confirmed
   inline invocations.
3. [ ] Write representative reusable jqz query files for real compiler jobs,
   including full original windows/fields where supported. Run jq and jqz with
   explicit argv and bounded process capture against existing inputs. Compare
   exact bytes or ordered JSON values with exact-decimal comparison, output
   cardinality and exit statuses. Include negative gates and counterexamples for
   unsupported features. Preserve hashes/counts, not private output payloads.
4. [ ] Document verified translations, required invocation changes, genuine
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
