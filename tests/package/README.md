# Separate public-API consumer

This is an independent Zig build/package graph. In the checkout, run
`zig build test --summary all` from `tests/package`; its dependency points at
`../..`. Eight tests cover the earlier stream/sort/group interface and the
expanded binding, named-feed, slurp, quantifier, decimal-statistics, scalar-array
aggregate, JSON serialization, Unicode byte-sizing, immutable path edits,
sorted-key output, structural sorting/distinctness and predicate-status APIs.
They overwrite caller buffers and destroy the input collector
before finishing downstream retention to check ownership through the public API.

For standalone qualification, copy `build.zig`, `build.zig.zon` and `main.zig`
into a separate directory beside an extracted source tree. Change only the
`json_query` dependency's `.path` to that tree. Use an empty local build cache,
an independent empty `ZIG_GLOBAL_CACHE_DIR`, and a local relative `zig-pkg`
package directory. This Zig 0.17.0 installation uses `ZIG_GLOBAL_CACHE_DIR`,
not a `zig build --global-cache-dir` option; keep `ZIG_LOCAL_PKG_DIR` relative.
Use native Debug, with no target/optimization overrides.

From the project root, `zig build verify-dist` automates these steps, including
quarantining all source caches/artifacts before starting this consumer. The
[implementation plan](../../docs/plans/2026-11-11-verify-dist.md) describes its
isolation, evidence and cleanup checks.

The [qualification report](../../docs/qualification/README.md) records the
executed source-package and separate-consumer checkpoint and archive hashes.
