## Commit Message Workflow

When creating a commit, first create a temporary file and write the complete commit message
into that file. Then create the commit with `git commit -F path_to_temp_file`. Do not use
`git commit -m`. Remove the temporary file after the commit succeeds.

Before committing a fix or feature:

1. Run `zig build version` and note the current package version.
2. Decide between a patch increment for a backward-compatible fix and a minor
   increment for a backward-compatible feature. Keep the current major component.
3. Never change the major component. Major-version changes are made only by the
   user. If a change would require a new major version, report that requirement and
   wait for the user to change the version before committing.
4. Run `zig build version -- set <new_sem_ver>` with the selected patch or minor
   version. This uses the pinned `zig-package-version` tool and the project's
   marker configuration in `tools/versions.json`.
5. Include every version file updated by that command in the fix or feature commit.

## Temporary Files

Remove any temporary file when it is no longer needed using plain `rm path_to_temp_file`,
without additional flags.

## Git Repository per Folder

Each project and modular component library folder must be initialized as its own independent Git repository (`git init`). Do not nest Git repositories or combine separate sibling libraries into a single monolithic repository.

## Slice Commits

Implement work in reviewable, verified slices. After each slice passes its focused checks and tests, create a commit for that slice before beginning the next one. Keep unrelated changes and multiple slices out of the same commit.
