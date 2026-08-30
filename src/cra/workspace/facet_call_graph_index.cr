require "facet/compiler"

module CRA
  class FacetCallGraphIndex
    getter extraction_count : Int64
    getter resolution_count : Int64

    private record CallSite,
      uri : String,
      owner_name : String,
      caller_name : String,
      caller_class_method : Bool,
      caller_node : Facet::Compiler::SyntaxNode,
      call_node : Facet::Compiler::SyntaxNode,
      range : Types::Range

    private record ResolvedEdge,
      caller : Psi::Method,
      target : Psi::Method,
      range : Types::Range

    def initialize
      @sites_by_uri = {} of String => Array(CallSite)
      @indexed_revisions = {} of String => UInt64
      @revision = 0_i64
      @resolved_revision = -1_i64
      @resolved_edges = [] of ResolvedEdge
      @extraction_count = 0_i64
      @resolution_count = 0_i64
    end

    # Syntax extraction is file-grained: unchanged files keep their call sites.
    # Semantic edges are resolved lazily because a declaration edit can change
    # targets in otherwise unchanged callers.
    def index(uri : String, tree : Facet::Compiler::SyntaxTree, source_revision : UInt64) : Nil
      return if @indexed_revisions[uri]? == source_revision

      sites = [] of CallSite
      tree.nodes(Facet::Compiler::NodeKind::Def).each do |definition|
        collect_definition_sites(uri, definition, sites)
      end
      tree.nodes(Facet::Compiler::NodeKind::Fun).each do |definition|
        collect_definition_sites(uri, definition, sites)
      end
      @sites_by_uri[uri] = sites
      @indexed_revisions[uri] = source_revision
      @revision += 1
      @extraction_count += 1
    end

    def incoming(
      item : Types::CallHierarchyItem,
      analyzer : Psi::SemanticIndex,
    ) : Array(NamedTuple(method: Psi::Method, ranges: Array(Types::Range)))
      ensure_resolved(analyzer)
      target_keys = method_keys_for_item(item, target: true)
      grouped = {} of String => NamedTuple(method: Psi::Method, ranges: Array(Types::Range))
      @resolved_edges.each do |edge|
        next unless target_keys.includes?(method_key(edge.target))
        key = method_key(edge.caller)
        entry = grouped[key]? || {method: edge.caller, ranges: [] of Types::Range}
        entry[:ranges] << edge.range unless entry[:ranges].any? { |range| ranges_equal?(range, edge.range) }
        grouped[key] = entry
      end
      grouped.values
    end

    def outgoing(
      item : Types::CallHierarchyItem,
      analyzer : Psi::SemanticIndex,
    ) : Array(NamedTuple(method: Psi::Method, ranges: Array(Types::Range)))
      ensure_resolved(analyzer)
      caller_keys = method_keys_for_item(item, target: false)
      grouped = {} of String => NamedTuple(method: Psi::Method, ranges: Array(Types::Range))
      @resolved_edges.each do |edge|
        next unless caller_keys.includes?(method_key(edge.caller))
        key = method_key(edge.target)
        entry = grouped[key]? || {method: edge.target, ranges: [] of Types::Range}
        entry[:ranges] << edge.range unless entry[:ranges].any? { |range| ranges_equal?(range, edge.range) }
        grouped[key] = entry
      end
      grouped.values
    end

    private def collect_definition_sites(
      uri : String,
      definition : Facet::Compiler::SyntaxNode,
      sites : Array(CallSite),
    ) : Nil
      owner_name = enclosing_type_name(definition)
      return unless owner_name
      caller_name = terminal_name(definition.name_node).try(&.symbol_name) || definition.name
      return unless caller_name
      body = definition.body
      return unless body

      seen = Set(String).new
      collect_calls(
        body,
        uri,
        owner_name,
        caller_name,
        definition_class_method?(definition),
        definition,
        sites,
        seen
      )
    end

    private def collect_calls(
      node : Facet::Compiler::SyntaxNode,
      uri : String,
      owner_name : String,
      caller_name : String,
      caller_class_method : Bool,
      caller_node : Facet::Compiler::SyntaxNode,
      sites : Array(CallSite),
      seen : Set(String),
    ) : Nil
      return if {
                  Facet::Compiler::NodeKind::Def,
                  Facet::Compiler::NodeKind::Fun,
                  Facet::Compiler::NodeKind::MacroDef,
                  Facet::Compiler::NodeKind::Class,
                  Facet::Compiler::NodeKind::Module,
                  Facet::Compiler::NodeKind::Struct,
                  Facet::Compiler::NodeKind::Enum,
                  Facet::Compiler::NodeKind::Lib,
                }.includes?(node.kind)

      candidate = if {Facet::Compiler::NodeKind::Call, Facet::Compiler::NodeKind::CallWithBlock,
                      Facet::Compiler::NodeKind::Binary}.includes?(node.kind) && node.call_name
                    node
                  elsif node.kind == Facet::Compiler::NodeKind::Ident && implicit_call_candidate?(node)
                    node
                  end
      if candidate
        span = call_name_span(candidate)
        if span
          key = "#{span.start}:#{span.finish}"
          unless seen.includes?(key)
            seen << key
            sites << CallSite.new(
              uri,
              owner_name,
              caller_name,
              caller_class_method,
              caller_node,
              candidate,
              range_for(candidate.tree, span)
            )
          end
        end
      end

      node.children.each do |child|
        collect_calls(child, uri, owner_name, caller_name, caller_class_method, caller_node, sites, seen)
      end
    end

    private def implicit_call_candidate?(node : Facet::Compiler::SyntaxNode) : Bool
      parent = node.parent
      return true unless parent
      return false if {Facet::Compiler::NodeKind::Param, Facet::Compiler::NodeKind::Path,
                       Facet::Compiler::NodeKind::TypeApply}.includes?(parent.kind)
      return false if {Facet::Compiler::NodeKind::Call, Facet::Compiler::NodeKind::CallWithBlock}.includes?(parent.kind) &&
                      parent.callee.try(&.id) == node.id
      return false if parent.kind == Facet::Compiler::NodeKind::NamedArg && parent.name_node.try(&.id) == node.id
      return false if {Facet::Compiler::NodeKind::Assign, Facet::Compiler::NodeKind::VarDecl}.includes?(parent.kind) &&
                      parent.target.try(&.id) == node.id
      true
    end

    private def ensure_resolved(analyzer : Psi::SemanticIndex) : Nil
      return if @resolved_revision == @revision
      @resolution_count += 1
      edges = [] of ResolvedEdge
      seen = Set(String).new
      @sites_by_uri.each_value do |sites|
        sites.each do |site|
          caller = resolve_caller(site, analyzer)
          next unless caller
          targets = if {"super", "previous_def"}.includes?(site.call_node.call_name || site.call_node.symbol_name)
                      analyzer.super_methods_for(caller)
                    else
                      resolve_targets(site, analyzer)
                    end
          targets.each do |target|
            next if method_key(caller) == method_key(target)
            key = "#{method_key(caller)}:#{method_key(target)}:#{site.uri}:#{site.range.start_position.line}:#{site.range.start_position.character}"
            next if seen.includes?(key)
            seen << key
            edges << ResolvedEdge.new(caller, target, site.range)
          end
        end
      end
      @resolved_edges = edges
      @resolved_revision = @revision
    end

    private def resolve_caller(site : CallSite, analyzer : Psi::SemanticIndex) : Psi::Method?
      path = site.caller_node.ancestors.reverse + [site.caller_node]
      offset = terminal_name(site.caller_node.name_node).try(&.name_span).try(&.start) || site.caller_node.span.start
      definitions = analyzer.find_facet_definitions(
        site.caller_node,
        path,
        offset,
        site.owner_name,
        site.uri
      )
      definitions.compact_map(&.as?(Psi::Method)).find do |method|
        method.name == site.caller_name &&
          method.class_method == site.caller_class_method &&
          method.owner.try(&.name) == site.owner_name &&
          method.file == site.uri
      end
    end

    private def resolve_targets(site : CallSite, analyzer : Psi::SemanticIndex) : Array(Psi::Method)
      path = site.call_node.ancestors.reverse + [site.call_node]
      span = call_name_span(site.call_node)
      definitions = analyzer.find_facet_definitions(
        site.call_node,
        path,
        span.try(&.start) || site.call_node.span.start,
        site.owner_name,
        site.uri
      )
      definitions.compact_map(&.as?(Psi::Method))
    end

    private def method_keys_for_item(item : Types::CallHierarchyItem, target : Bool) : Set(String)
      if data = item.data.try(&.as_h?)
        if key = data["facetMethodKey"]?.try(&.as_s?)
          return Set{key}
        end
      end

      keys = Set(String).new
      @resolved_edges.each do |edge|
        method = target ? edge.target : edge.caller
        next unless method.name == item.name
        next unless method.file == item.uri
        next unless location_matches?(method.location, item.range)
        keys << method_key(method)
      end
      keys
    end

    private def method_key(method : Psi::Method) : String
      owner = method.owner.try(&.name) || ""
      "method:#{owner}:#{method.class_method ? "class" : "instance"}:#{method.name}"
    end

    private def enclosing_type_name(node : Facet::Compiler::SyntaxNode) : String?
      names = [] of String
      (node.ancestors.reverse + [node]).each do |candidate|
        next unless {
                      Facet::Compiler::NodeKind::Class,
                      Facet::Compiler::NodeKind::Module,
                      Facet::Compiler::NodeKind::Struct,
                      Facet::Compiler::NodeKind::Enum,
                      Facet::Compiler::NodeKind::Lib,
                    }.includes?(candidate.kind)
        name = candidate.name
        next unless name
        names = name.includes?("::") ? [name] : names + [name]
      end
      names.empty? ? nil : names.join("::")
    end

    private def definition_class_method?(node : Facet::Compiler::SyntaxNode) : Bool
      name = node.name_node
      !!(name && {Facet::Compiler::NodeKind::Path, Facet::Compiler::NodeKind::Binary}.includes?(name.kind))
    end

    private def terminal_name(node : Facet::Compiler::SyntaxNode?) : Facet::Compiler::SyntaxNode?
      return nil unless node
      current = node
      while {Facet::Compiler::NodeKind::Path, Facet::Compiler::NodeKind::Binary}.includes?(current.kind)
        current = current.children.last
      end
      current = current.child(0) || current if current.kind == Facet::Compiler::NodeKind::TypeApply
      current
    end

    private def call_name_span(node : Facet::Compiler::SyntaxNode) : Facet::Compiler::Span?
      if node.call_name
        terminal_name(node.callee).try(&.name_span)
      else
        node.name_span
      end
    end

    private def range_for(tree : Facet::Compiler::SyntaxTree, span : Facet::Compiler::Span) : Types::Range
      start_position = tree.position_at(span.start)
      end_position = tree.position_at(span.finish)
      Types::Range.new(
        Types::Position.new(start_position.line, start_position.character),
        Types::Position.new(end_position.line, end_position.character)
      )
    end

    private def location_matches?(location : Psi::Location?, range : Types::Range) : Bool
      return false unless location
      location.start_line == range.start_position.line &&
        location.start_character == range.start_position.character &&
        location.end_line == range.end_position.line &&
        location.end_character == range.end_position.character
    end

    private def ranges_equal?(left : Types::Range, right : Types::Range) : Bool
      left.start_position.line == right.start_position.line &&
        left.start_position.character == right.start_position.character &&
        left.end_position.line == right.end_position.line &&
        left.end_position.character == right.end_position.character
    end
  end
end
