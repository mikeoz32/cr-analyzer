# Semantic Index

SemanticIndex is the core semantic database used for completion and definition.
The Facet-native producer populates the primary editor index; the temporary
Crystal producer remains as a fallback for unsupported type-aware macro
expansion and semantic shapes.

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

Include/extend and superclass edges are tracked. When a file changes, dependent types and their files are reindexed.

## Macro expansion

Supported macros:

- Facet-native: accessor macro families, `record`, and user-defined macros in
  the supported lexical/control/value subset
- Crystal fallback: unsupported compile-time type introspection and AST-node
  macro APIs

Facet-generated nodes are indexed under `facet-macro:` virtual URIs. Legacy
fallback nodes retain `crystal-macro:` URIs until the cutover is complete.
