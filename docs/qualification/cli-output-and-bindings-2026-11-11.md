# Joined output and file-binding qualification

The [implementation plan](../plans/2026-11-11-cli-output-and-file-bindings.md)
is complete. Joined output shipped in 0.29.0; named JSON/text bindings and final
qualification pass at 0.30.0. All builds and checks use native x86_64 Linux Debug.

## Joined output, 0.29.0

Feature snapshot `9e38a71` passes native Debug build, all 240 project checks and
nine separate consumer checks. Coverage includes embedded NUL/Unicode,
empty-string predicate status, non-string/sorted JSON, flag bundles, query files,
completion/early stop, partial writes and output failure precedence.

[Generated live evidence](2026-11-11-join-output.json) rechecks the original
three compiler path manifests from records 25,240, 25,600 and 25,899. All jq/jqz
outputs and exits match exactly, with 171,036, 171,424 and 171,708 bytes
respectively. Inputs are stable before/after each pair. The new
[query file](../../examples/zllvm/nul-paths.query) runs with `-j` or `-jr`; keys
remain sorted and each path is followed by NUL without an extra newline.

The [Zig check helper](../experiments/cli_features.zig) uses explicit argv,
10-second deadlines, bounded capture and input/tool hashes. It reads retained
compiler JSON and discards output payloads after comparison. The 0.28.0 audit
and its original counterexamples are preserved unchanged. These checks verify
the concrete framing requirement and add no observed-query coverage or
performance claim.

After `zig build`, the current helper rechecks the three joined-output cases:

```sh
jqz_support=zig-pkg/test_support-0.2.0-WfGxyjo5BAB0686gSkz5ucgtYJWyK1q9Idd0xXji0hue
zig run --dep test_support -Mroot=docs/experiments/cli_features.zig --dep process \
  -Mtest_support="$jqz_support/src/root.zig" \
  -Mprocess="$jqz_support/vendor/zig-process/src/root.zig" -- \
  zig-out/bin/jqz zig-out/qualification/local-cli-features.json
```

Evidence is a byte-identical copy of generated JSON and pins the compiler-audit
source record, query, helper and tool identities. The original 0.29.0 helper is
preserved in commit `3b00725`; current runs produce their own version/fingerprints.

## Named file bindings, 0.30.0

Feature snapshot `7ff39ed` passes native Debug build and all 249 project checks
(160 library, 53 CLI, three binding-input, four version, three qualification,
eighteen profiler and eight distribution-verifier checks). File-binding checks
cover empty/multiline/adjacent JSON values, exact numbers, duplicate decoded
keys, raw UTF-8/NUL bytes, invalid/truncated/unused values, names, shared size
limits, array-wrapper depth, literal dash filenames, query/stdin composition,
early stopping, non-positional bounded reads and allocation-failure cleanup.

The [fresh live evidence](2026-11-11-file-bindings.json) passes all five pairs.
It repeats the same three NUL-path checks after CLI changes and adds two
component scenarios outside observed coverage:

| Component | Input and comparison | Result |
| --- | --- | --- |
| `--slurpfile before/after` | First two retained source manifests; compare document counts, file counts and `.files` equality using the ready query | 65 identical output bytes, zero exits |
| `--rawfile text` with `-nj` | Compiler `docs/validation_tools.md` passed through as text | 27,205 identical bytes, zero exits; output SHA-256 also equals the input hash |

All input/tool hashes remain stable before/after the comparisons. Each original
path manifest must also match its frozen 0.28.0 audit hash. Schema 2 marks new
components with null `source_record`, records the binding implementation and
query hashes, and preserves bounded explicit-argv execution. The compiler
checkout remains clean. No compiler workloads or historical shell text run.

The [unchanged corpus replay](2026-11-11-file-bindings-corpus.json) passes all
45 cases: 30/30 selected observed translations, zero unsupported cases or
invocation adaptations, three components, ten intentional probes and two scale
cases. The 35 timed equivalent cases yield 70 samples at one repetition; this
is functional regression evidence, with no new performance claim. The two live
binding components above are separate from these corpus counts. Earlier raw
evidence, corpus queries/expectations and exact-arithmetic differences remain
unchanged. Larger `as`/`def`/`reduce` scripts and dynamic indexes remain outside
this implementation.

To include both binding components, append `--file-bindings` to the helper
invocation above; then replay the corpus:

```sh
zig run --dep test_support -Mroot=docs/experiments/cli_features.zig --dep process \
  -Mtest_support="$jqz_support/src/root.zig" \
  -Mprocess="$jqz_support/vendor/zig-process/src/root.zig" -- \
  zig-out/bin/jqz zig-out/qualification/local-cli-features.json --file-bindings
zig build qualify -- --repeat 1 --out zig-out/qualification/local-corpus.json
```

Both reports are unmodified copies of generated JSON. SHA-256:

- Live CLI evidence: `41b4fcf921d6e072d2e4a19a53a686d0a655af6bba856b8482f8020dd0cef8d6`.
- Corpus replay: `35d514be27db4c1c2b647771a21fef81776b383d53c3ae5ef5a82eb801f7378e`.
