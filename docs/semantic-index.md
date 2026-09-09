# Semantic Index

SemanticIndex is the core semantic database used for completion and definition.
The Facet-native producer populates the primary editor index; the temporary
Crystal producer remains as a fallback for unsupported type-aware macro
expansion and semantic shapes.

Facet 0.2.0 additionally owns the compiler-facing `SemanticDb`. It returns
immutable tolerant/strict snapshots with `NodeRef`, `DefId`, `MethodId`, and
canonical `TypeId` handles. `CRA::Psi::SemanticIndex` is currently an adapter
and fallback; new compiler semantics belong in Facet rather than in LSP code.

## Data model

- PsiElement base class with file and location.
- Types: Module, Class, Enum, Method, InstanceVar, ClassVar, LocalVar, Alias, EnumMember.
- TypeRef: lightweight type handle with a name, generic args, and union variants.

## Indexing passes

- FacetSemanticIndexer skeleton pass: builds type shells and records type variables.
- FacetSemanticIndexer semantic pass: attaches methods, includes, inheritance,
  enum members, and aliases.
- Legacy SkeletonIndexer/SemanticIndexer: retains macro-expanded declarations
  until the expansion cutover is complete.
- FacetCallGraphIndex: replaces call sites only for reindexed files, then lazily
  resolves and revision-caches incoming/outgoing semantic edges.
- Facet expanded-declaration pass: subtracts raw declaration contracts from the
  cached expanded tree and indexes only generated declarations under a stable
  virtual URI.
- Macro pre-expansion: expands supported macros into virtual files for indexing.

## Type hints

Type inference is intentionally light. The indexer extracts TypeRef from:

- explicit type annotations
- simple assignments when the RHS is a Foo.new call
- array or hash literals with an explicit of type
- casts, metaclasses, and union/generic type syntax

`Facet::Compiler::SemanticDb` separately covers literals, assignments,
constructors, annotated and simply inferred method returns, generic receiver
substitution, unions, inheritance/includes, arity-filtered lookup, scoped
constant definitions and lazy values, enum-member types, and macro-generated
entry-file declarations. Overload selection understands built-in numeric
ancestry, receiver-relative `self`, structural tuple/generic restrictions,
blocks, named arguments, double splats, duplicate signatures, and per-member
union dispatch. Constant lookup follows lexical, absolute, nested,
ancestor/include, and `forall` metaclass paths; required-file edits invalidate
dependent snapshots. Conditional flow narrows truthiness, `nil?`, and `is_a?`
through negation and short-circuit expressions, merges branch assignments, and
retains explicit return types while excluding terminated guards. Incomplete
facts remain `Unknown`.

## Semantic diagnostics

`facet.undefined_method` is emitted only when every closed receiver member has
a complete lookup and none defines the method. Facet also emits coded
`facet.undefined_constant`, `facet.undefined_local`, `facet.constant_cycle`,
and `facet.constant_as_type` diagnostics for the exact supported compiler
contracts. Unknown receivers, unresolved requires, parser recovery, incomplete
macro expansion, and `method_missing` suppress or mark uncertain findings
provisional. cr-analyzer computes all findings in shadow mode by default;
`CRA_FACET_SEMANTICS=on` publishes only conclusive findings with source
`facet-semantic`.

## Resolution

find_definitions resolves:

- types and namespaces (Path, Generic)
- enum members
- aliases
- methods with arity filtering, including inherited methods (including class vs instance, includes, superclasses)
- locals, instance vars, class vars
- constructors (new -> initialize/self.new)
- call hierarchy edges (outgoing/incoming) via Facet-resolved calls
- references for types/aliases across files (path matching)

## Dependencies

Include/extend and superclass edges are tracked by the Facet semantic index.
When a file changes, its old and new type names invalidate dependent files even
in `CRA_FACET_ONLY=1` mode. Public navigation tests verify that inherited and
included methods disappear after their provider declaration is removed.

## Macro expansion

Supported macros:

- Facet-native: accessor macro families, `record`, and user-defined macros in
  the supported lexical/control/value subset, including lexical `@type`,
  indexed `resolve`, member/constant metadata, and explicit ancestry
- Crystal fallback: remaining contextual compiler/type, AST-node, and error APIs

Facet-generated nodes are indexed under `facet-macro:` virtual URIs. Legacy
fallback nodes retain `crystal-macro:` URIs until the cutover is complete.
