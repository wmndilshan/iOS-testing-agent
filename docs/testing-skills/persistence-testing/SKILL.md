---
name: persistence-testing
description: Testing stores, journals and files: round trip, reopen, atomic failure and schema versions.
scope: technology
applies-to:
  technologies: [persistence, sqlite]
  categories: [persistence]
directives:
  storage-location: a unique temporary directory per test, removed with defer
---
## Round trip and reopen
Write, read back, then open a fresh instance on the same location and read again.

## Failure
A failed or interrupted write must leave the previous data readable. Corrupt files are detected, not silently
replaced.

## Versions
<!-- when: traits=dataMigration -->
Keep a fixture of the previous format; older versions decode or migrate, unknown newer versions fail closed.
