# Current standalone source package and independent consumer

Status: authorized implementation in progress, starting from jqz 0.26.2.

## Objective and scope

Close the gap between the verified 0.26.2 checkout and the historical
[0.12.0 extracted-package checkpoint](../qualification/package-evidence.json).
Use the existing deterministic `zig build dist` archive, bundled dependencies,
45-case workflow corpus and eight-test public-API consumer. Then exercise the
packaged binary on additional practical project-report/configuration queries.

All verification uses native x86_64 Linux Debug. No other target or optimization
mode, network publication, sibling development library or new language feature
is part of this work. Existing Zig, Git, GNU tar/gzip, jq, GNU time and checksum
tools are available; no additional tool is required. If implementation becomes
necessary, use Zig and the existing pinned tooling.

## Contracts

- Preserve the original runtime, corpus expectations and historical evidence.
  Verification/documentation alone keeps 0.26.2. Before committing a discovered
  runtime/package fix, read `zig build version`, keep major 0, select a patch
  increment and use `zig build version -- set VERSION`; include every marker.
- Freeze a committed snapshot before archiving. Record the source commit,
  archive size/hash, complete file checksum manifest and tool identities. Build
  twice without changing inputs and require identical archive bytes.
- Verify archive members against the intended tracked payload, including all
  pinned vendor archives and licenses/provenance. Exclude caches, build outputs
  and Git metadata. Check all bundled dependency checksums after extraction.
- Extract outside this checkout. Initialize source and consumer as independent
  sibling Git repositories, without a parent or nested repository. Use initially
  empty, distinct local/global caches and absent relative package directories.
- Copy the consumer from the archive; change only its `json_query` dependency
  path to the extracted source. Preserve its build/main fingerprints. Quarantine
  the source caches/build outputs before building the consumer, so the consumer
  cannot reuse those artifacts.
- Record exact commands, working directories, relevant environment, exit codes,
  test totals, raw logs and binary hashes. Debug paths may change binary bytes;
  do not confuse that with archive nondeterminism or source drift.
- The archive is a qualified snapshot. Final result documents are written after
  archiving to avoid a self-referential archive hash. Identify that boundary and
  do not claim the later documentation commit has the same complete archive hash.
- New practical query checks are distinct from the selected 30 observed session
  translations. Do not increase that coverage denominator or call a smoke replay
  a new performance baseline.

## Verified implementation slices

Commit each verified slice before starting the next. Write complete commit
messages to temporary files, use `git commit -F`, and remove temporary files
with plain `rm`, without flags.

1. [x] Record this plan and link it from project/package documentation. Review
   the existing archive recipe, dependency manifests and separate consumer;
   verify links/diff and commit the snapshot before qualification.
2. [ ] Build and inspect the current archive:
   - Run `zig build dist` twice on the frozen snapshot; compare SHA-256 and bytes.
   - Match archive members to the intended tracked files, check exclusion of
     caches/Git/build outputs, and preserve a complete SHA-256 file manifest.
   - Record compiler/tar identities and keep the qualified archive in `zig-out`.
3. [ ] Verify a fresh extraction:
   - Initialize an independent source repository outside the checkout and check
     every extracted file against the manifest and all three vendor checksums.
   - With fresh local/global caches and an absent `zig-pkg`, run native Debug
     build/tests and verify the installed CLI version. Require all 220 existing
     project checks, updating the expected total only for meaningful new checks.
   - Replay all 45 frozen corpus cases at one repetition (68 timing smoke
     samples). Preserve 30/30 observed translations and ten intentional probes;
     compare runtime/corpus fingerprints with the current checkout evidence.
4. [ ] Verify an independent consumer:
   - Copy its files from the archive, adjust only the dependency path and
     initialize its own sibling repository. Confirm unchanged main/build files.
   - Move source caches/package directory/build outputs aside. Run all eight
     consumer checks with distinct fresh caches/package directory and confirm
     the quarantined source artifacts were unnecessary.
5. [ ] Exercise practical queries and publish the checkpoint:
   - Use the extracted CLI to summarize the bundled qualification report,
     identify its slowest measured jqz cases and inspect version-marker coverage.
     Check each result independently with installed jq; record queries, input
     hashes and output/status evidence separately from session-corpus coverage.
   - Publish a new dated package-evidence JSON, raw packaged corpus replay,
     source/consumer logs and complete file checksum manifest. Link the latest
     checkpoint and leave 0.12.0 evidence unchanged. Record any real query gap;
     do not add speculative syntax when the queries already work.
   - Verify fingerprints, links and diff; mark this plan complete and commit.
     Remove temporary files using plain `rm` and empty directories with `rmdir`;
     retain the qualified archive and evidence. Any genuine package fix gets a
     separate verified/versioned commit followed by qualification of that fix.

## Completion

The current archive rebuilds identically, contains all required sources and
dependencies, and passes fresh extracted-source and independent-consumer checks
without checkout caches. New practical queries have recorded results or an
explicit concrete gap. The report clearly separates the frozen package snapshot,
later documentation, smoke replay and prior performance measurements.

## Implementation record

Planning: reviewed the archive's explicit roots and normalized tar options,
all three relative `file:vendor` dependencies, current 220 project checks,
45-case corpus and eight consumer checks. The existing consumer covers buffer
ownership, stream/binding/provenance APIs, scalar aggregates, Unicode sizing,
immutable edits, structural sets and predicate status. No code change has been
found necessary before qualification.
