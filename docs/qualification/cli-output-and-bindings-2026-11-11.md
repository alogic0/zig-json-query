# Joined output and file-binding qualification

The [implementation plan](../plans/2026-11-11-cli-output-and-file-bindings.md)
tracks two verified CLI features. Joined output is implemented in 0.29.0;
file-binding implementation and final qualification follow in the next slice.

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

Reproduce from the jqz checkout after `zig build`:

```sh
jqz_support=zig-pkg/test_support-0.2.0-WfGxyjo5BAB0686gSkz5ucgtYJWyK1q9Idd0xXji0hue
zig run --dep test_support -Mroot=docs/experiments/cli_features.zig --dep process \
  -Mtest_support="$jqz_support/src/root.zig" \
  -Mprocess="$jqz_support/vendor/zig-process/src/root.zig" -- \
  zig-out/bin/jqz zig-out/qualification/local-cli-features.json
```

Evidence is a byte-identical copy of generated JSON and pins the compiler-audit
source record, query, helper and tool identities. Later feature slices can
produce fresh evidence with their own version/fingerprints.
