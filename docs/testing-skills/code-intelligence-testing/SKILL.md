---
name: code-intelligence-testing
description: Testing the AST index, change analysis and test planner in the CodeIntelligence target.
scope: module
applies-to:
  modules: [CodeIntelligence]
  technologies: [swiftsyntax]
directives:
  source-fixtures: inline Swift source strings; no dependency on the real repository layout
---
## Inputs
Index small inline Swift sources with `SwiftFileIndexer.index(path:module:role:source:)`, or build an `ASTIndex`
from them. Use `SnapshotChangeSource` over two temporary directories instead of git where possible.

## Determinism
Assert exact symbol IDs, aspects and statuses. Running the same input twice must give identical output.
