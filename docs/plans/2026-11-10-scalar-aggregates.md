# Scalar aggregates inside report summaries

Status: implementation in progress; authorized on 2026-11-10.

## Objective and contracts

Close the `embedded-total-summary` and `embedded-group-summary` gaps identified
by the [workflow qualification](../qualification/README.md). Preserve outer
report fields while computing array totals and grouped counts inside an object.
Use Zig for implementation and native x86_64 Linux Debug for all validation.

- `sum(array)` evaluates its argument once and returns one checked i128 integer.
  Empty arrays produce `0`; integral decimal/exponent tokens are accepted.
  Fractional values, nonnumbers and overflowing intermediate totals fail, with
  the source element path when available. The existing `sum` stage is unchanged.
- `group_by(array, key)` evaluates the array once and the key once per element,
  with `.` bound to that element. Structural equality and first-seen group order
  match the existing stream stage; members retain input order. Empty input gives
  `[]`. Missing keys require an explicit default. Mixed and container keys work.
- `sort_by(array, key)` returns one stably sorted array. Keys must be uniformly
  numeric or uniformly strings, using the existing exact comparison rules.
  Empty input gives `[]`. This function supplies the explicit key ordering
  needed to match jq's grouped-summary array without changing group semantics.
- One-argument `group_by(key)` and `sort_by(key)` remain stream stages. Scalar
  forms require two arguments, work nested in objects/functions and support
  ordinary postfix access and operators. Nested pipes remain unsupported.
- Array operations borrow children for the synchronous scalar-stage lifetime.
  Retaining stages continue to clone results into their shared memory budget.
  Scalar scratch allocations are not a new total-memory guarantee. Grouping
  keeps the existing quadratic scan; sorting reuses the stable comparator.

## Verified commit slices

1. [x] Record this implementation plan before changing the language.
2. [ ] Implement `sum(array)` with parser disambiguation, exact numeric rules,
   source diagnostics and nested/empty/error/overflow/allocation tests. Update
   language documentation. Check the current version and increment its minor
   component using `zig build version -- set`; commit the verified feature.
3. [ ] Add scalar grouping and sorting, sharing row sorting/group construction
   with stream stages. Cover parser compatibility, stable ordering, structural
   keys, nested scopes/paths, lifetime/retention and allocation failure. Extend
   the separate package consumer. Document the functions and commit with the
   next minor version after native Debug build/tests and consumer checks pass.
4. [ ] Translate the two blocked corpus workflows, preserving their frozen jq
   expectations and ordered arrays. Re-run the complete qualification with five
   repetitions in native Debug. Save a new evidence checkpoint, retain the
   historical 0.12.0 evidence, report coverage and remaining gaps, and mark this
   plan complete. Commit the verified corpus/report slice separately.

## Acceptance

Both target summaries match jq while retaining their report context. Existing
language/CLI/version checks pass, with no change to stream order, strict typing,
exact arithmetic or missing-value semantics. The selected observed coverage
increases from 25/30 to 27/30; the other three unsupported workflows remain
explicitly classified. No additional target or optimization-mode matrix is run.

## Validation record

Plan recorded; implementation checks pending.
