require "facet/compiler"

module CRA
  record FacetOccurrence, uri : String, range : Types::Range

  class Workspace
    private def facet_reference_locations(
      document : WorkspaceDocument,
      position : Types::Position,
      uri : String,
      include_declaration : Bool,
    ) : Array(Types::Location)?
      finder = document.facet_node_context(position)
      return nil unless finder
      node = finder.semantic_node
      return nil unless node && facet_renameable?(node)
      name = facet_symbol_name(node)
      return nil unless name && !name.empty?

      occurrences = case node.kind
                    when Facet::Compiler::NodeKind::Param, Facet::Compiler::NodeKind::Splat,
                         Facet::Compiler::NodeKind::DoubleSplat, Facet::Compiler::NodeKind::BlockParam
                      if name.starts_with?("@@")
                        type_name = finder.enclosing_type_name
                        type_name ? facet_scoped_variable_occurrences(type_name, name, Facet::Compiler::NodeKind::ClassVar) : [] of FacetOccurrence
                      elsif name.starts_with?("@")
                        type_name = finder.enclosing_type_name
                        type_name ? facet_scoped_variable_occurrences(type_name, name, Facet::Compiler::NodeKind::InstanceVar) : [] of FacetOccurrence
                      else
                        facet_local_occurrences(finder, name, uri, include_declaration)
                      end
                    when Facet::Compiler::NodeKind::InstanceVar, Facet::Compiler::NodeKind::ClassVar
                      type_name = finder.enclosing_type_name
                      type_name ? facet_scoped_variable_occurrences(type_name, name, node.kind) : [] of FacetOccurrence
                    when Facet::Compiler::NodeKind::Call, Facet::Compiler::NodeKind::CallWithBlock,
                         Facet::Compiler::NodeKind::Binary, Facet::Compiler::NodeKind::Def,
                         Facet::Compiler::NodeKind::Fun
                      definitions = @facet_analyzer.find_facet_definitions(
                        node, finder.context_path, finder.byte_offset, finder.enclosing_type_name, uri
                      )
                      keys = method_keys_for(definitions)
                      keys.empty? ? [] of FacetOccurrence : facet_method_occurrences(keys, include_declaration)
                    when Facet::Compiler::NodeKind::Ident
                      if !name[0].ascii_uppercase?
                        definitions = @facet_analyzer.find_facet_definitions(
                          node, finder.context_path, finder.byte_offset, finder.enclosing_type_name, uri
                        )
                        keys = method_keys_for(definitions)
                        keys.empty? ? facet_local_occurrences(finder, name, uri, include_declaration) : facet_method_occurrences(keys, include_declaration)
                      else
                        facet_type_reference_occurrences(node, finder, uri, include_declaration)
                      end
                    else
                      facet_type_reference_occurrences(node, finder, uri, include_declaration)
                    end

      occurrences.map { |occurrence| Types::Location.new(uri: occurrence.uri, range: occurrence.range) }
    rescue ex
      Log.error { "Facet references failed: #{ex.message}" }
      nil
    end

    private def facet_type_reference_occurrences(
      node : Facet::Compiler::SyntaxNode,
      finder : FacetNodeFinder,
      uri : String,
      include_declaration : Bool,
    ) : Array(FacetOccurrence)
      definitions = @facet_analyzer.find_facet_definitions(
        node, finder.context_path, finder.byte_offset, finder.enclosing_type_name, uri
      )
      keys = type_keys_for(definitions)
      keys.empty? ? [] of FacetOccurrence : facet_type_occurrences(keys, include_declaration)
    end

    private def facet_local_occurrences(
      finder : FacetNodeFinder,
      name : String,
      uri : String,
      include_declaration : Bool = true,
    ) : Array(FacetOccurrence)
      path = finder.context_path
      block_scope = path.reverse_each.find do |node|
        {Facet::Compiler::NodeKind::Block, Facet::Compiler::NodeKind::CallWithBlock}.includes?(node.kind) &&
          node.parameters.any? { |parameter| parameter.name == name }
      end

      occurrences = [] of FacetOccurrence
      seen = Set(String).new
      if block_scope
        if include_declaration
          block_scope.parameters.each do |parameter|
            add_facet_occurrence(occurrences, seen, uri, parameter) if parameter.name == name
          end
        end
        block_scope.body.try do |body|
          collect_facet_local_occurrences(body, name, uri, occurrences, seen)
        end
        return occurrences
      end

      definition = finder.enclosing_def
      return occurrences unless definition
      if include_declaration
        definition.parameters.each do |parameter|
          add_facet_occurrence(occurrences, seen, uri, parameter) if parameter.name == name
        end
      end
      definition.body.try do |body|
        collect_facet_local_occurrences(body, name, uri, occurrences, seen)
      end
      occurrences
    end

    private def collect_facet_local_occurrences(
      node : Facet::Compiler::SyntaxNode,
      name : String,
      uri : String,
      occurrences : Array(FacetOccurrence),
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

      if {Facet::Compiler::NodeKind::Block, Facet::Compiler::NodeKind::CallWithBlock}.includes?(node.kind) &&
         node.parameters.any? { |parameter| parameter.name == name }
        if node.kind == Facet::Compiler::NodeKind::CallWithBlock
          node.child(0).try { |call| collect_facet_local_occurrences(call, name, uri, occurrences, seen) }
        end
        return
      end

      if node.kind == Facet::Compiler::NodeKind::Ident && node.symbol_name == name && facet_local_identifier?(node)
        add_facet_occurrence(occurrences, seen, uri, node)
      end
      node.children.each do |child|
        collect_facet_local_occurrences(child, name, uri, occurrences, seen)
      end
    end

    private def facet_local_identifier?(node : Facet::Compiler::SyntaxNode) : Bool
      parent = node.parent
      return true unless parent
      case parent.kind
      when Facet::Compiler::NodeKind::Call, Facet::Compiler::NodeKind::CallWithBlock
        return false if parent.callee.try(&.id) == node.id
      when Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Fun,
           Facet::Compiler::NodeKind::MacroDef, Facet::Compiler::NodeKind::Class,
           Facet::Compiler::NodeKind::Module, Facet::Compiler::NodeKind::Struct,
           Facet::Compiler::NodeKind::Enum, Facet::Compiler::NodeKind::Lib,
           Facet::Compiler::NodeKind::Alias, Facet::Compiler::NodeKind::TypeDef,
           Facet::Compiler::NodeKind::AnnotationDef
        return false if parent.name_node.try(&.id) == node.id
      when Facet::Compiler::NodeKind::Param
        return false
      when Facet::Compiler::NodeKind::Path, Facet::Compiler::NodeKind::TypeApply
        return false
      end
      true
    end

    private def facet_scoped_variable_occurrences(
      type_name : String,
      name : String,
      kind : Facet::Compiler::NodeKind,
    ) : Array(FacetOccurrence)
      occurrences = [] of FacetOccurrence
      seen = Set(String).new
      workspace_file_uris.each do |uri|
        tree = @facet_store.syntax(uri)
        next unless tree
        tree.root.descendants.each do |type_node|
          next unless {Facet::Compiler::NodeKind::Class, Facet::Compiler::NodeKind::Struct}.includes?(type_node.kind)
          next unless facet_enclosing_type_name_for(type_node) == type_name
          type_node.body.try do |body|
            collect_facet_scoped_occurrences(body, name, kind, uri, occurrences, seen)
          end
        end
      end
      occurrences
    end

    private def collect_facet_scoped_occurrences(
      node : Facet::Compiler::SyntaxNode,
      name : String,
      kind : Facet::Compiler::NodeKind,
      uri : String,
      occurrences : Array(FacetOccurrence),
      seen : Set(String),
    ) : Nil
      return if {
                  Facet::Compiler::NodeKind::Class,
                  Facet::Compiler::NodeKind::Module,
                  Facet::Compiler::NodeKind::Struct,
                  Facet::Compiler::NodeKind::Enum,
                  Facet::Compiler::NodeKind::Lib,
                  Facet::Compiler::NodeKind::MacroDef,
                }.includes?(node.kind)
      add_facet_occurrence(occurrences, seen, uri, node) if node.kind == kind && node.symbol_name == name
      node.children.each do |child|
        collect_facet_scoped_occurrences(child, name, kind, uri, occurrences, seen)
      end
    end

    private def facet_method_occurrences(
      target_keys : Hash(String, Bool),
      include_declarations : Bool = true,
    ) : Array(FacetOccurrence)
      occurrences = [] of FacetOccurrence
      seen = Set(String).new
      target_names = target_keys.each_key.map { |key| key.split(':').last }.to_set

      workspace_file_uris.each do |uri|
        tree = @facet_store.syntax(uri)
        next unless tree

        tree.root.descendants.each do |node|
          if {Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Fun}.includes?(node.kind)
            next unless include_declarations
            name = facet_terminal_name(node.name_node).try(&.symbol_name) || node.name
            next unless name && target_names.includes?(name)
            owner = facet_enclosing_type_name_for(node)
            next unless owner
            key = method_key(owner, facet_definition_class_method?(node), name)
            add_facet_occurrence(occurrences, seen, uri, node, facet_terminal_name_span(node.name_node)) if target_keys[key]?
            next
          end

          if node.kind == Facet::Compiler::NodeKind::Ident && target_names.includes?(node.symbol_name.to_s) && facet_local_identifier?(node)
            definitions = facet_definitions_for_candidate(node, uri)
            if method_keys_for(definitions).each_key.any? { |key| target_keys[key]? }
              add_facet_occurrence(occurrences, seen, uri, node)
            end
            next
          end

          next unless {Facet::Compiler::NodeKind::Call, Facet::Compiler::NodeKind::CallWithBlock,
                       Facet::Compiler::NodeKind::Binary}.includes?(node.kind)
          name = node.call_name
          next unless name && target_names.includes?(name)
          definitions = facet_definitions_for_candidate(node, uri)
          next unless method_keys_for(definitions).each_key.any? { |key| target_keys[key]? }
          add_facet_occurrence(occurrences, seen, uri, node, facet_terminal_name_span(node.callee))
        end
      end
      occurrences
    end

    private def facet_type_occurrences(
      target_keys : Hash(String, Bool),
      include_declarations : Bool = true,
    ) : Array(FacetOccurrence)
      occurrences = [] of FacetOccurrence
      seen = Set(String).new
      workspace_file_uris.each do |uri|
        tree = @facet_store.syntax(uri)
        next unless tree

        tree.root.descendants.each do |node|
          if {
               Facet::Compiler::NodeKind::Class,
               Facet::Compiler::NodeKind::Module,
               Facet::Compiler::NodeKind::Struct,
               Facet::Compiler::NodeKind::Enum,
             }.includes?(node.kind)
            next unless include_declarations
            name = facet_enclosing_type_name_for(node)
            if name && target_keys["type:#{name}"]?
              add_facet_occurrence(occurrences, seen, uri, node, facet_terminal_name_span(node.name_node))
            end
            next
          elsif {Facet::Compiler::NodeKind::Alias, Facet::Compiler::NodeKind::TypeDef}.includes?(node.kind)
            next unless include_declarations
            name = facet_qualified_declaration_name(node)
            if name && target_keys["type:#{name}"]?
              add_facet_occurrence(occurrences, seen, uri, node, facet_terminal_name_span(node.name_node))
            end
            next
          end

          next unless {Facet::Compiler::NodeKind::Ident, Facet::Compiler::NodeKind::Const,
                       Facet::Compiler::NodeKind::Path}.includes?(node.kind)
          parent = node.parent
          next if parent && {Facet::Compiler::NodeKind::Path, Facet::Compiler::NodeKind::TypeApply}.includes?(parent.kind)
          next if parent && facet_declaration_node?(parent) && parent.name_node.try(&.id) == node.id

          definitions = facet_definitions_for_candidate(node, uri)
          next unless type_keys_for(definitions).each_key.any? { |key| target_keys[key]? }
          span = node.kind == Facet::Compiler::NodeKind::Path ? facet_terminal_name_span(node) : node.name_span
          add_facet_occurrence(occurrences, seen, uri, node, span)
        end
      end
      occurrences
    end

    private def facet_definitions_for_candidate(
      node : Facet::Compiler::SyntaxNode,
      uri : String,
    ) : Array(Psi::PsiElement)
      path = node.ancestors.reverse + [node]
      @facet_analyzer.find_facet_definitions(
        node,
        path,
        node.name_span.try(&.start) || node.span.start,
        facet_enclosing_type_name_for(node),
        uri
      )
    rescue
      [] of Psi::PsiElement
    end

    private def facet_enclosing_type_name_for(node : Facet::Compiler::SyntaxNode) : String?
      names = [] of String
      (node.ancestors.reverse + [node]).each do |candidate|
        next unless {
                      Facet::Compiler::NodeKind::Class,
                      Facet::Compiler::NodeKind::Module,
                      Facet::Compiler::NodeKind::Struct,
                      Facet::Compiler::NodeKind::Enum,
                    }.includes?(candidate.kind)
        name = candidate.name
        next unless name
        if name.includes?("::")
          names = [name]
        else
          names << name
        end
      end
      names.empty? ? nil : names.join("::")
    end

    private def facet_qualified_declaration_name(node : Facet::Compiler::SyntaxNode) : String?
      name = node.name
      return nil unless name
      owner = node.ancestors.find do |candidate|
        {Facet::Compiler::NodeKind::Class, Facet::Compiler::NodeKind::Module,
         Facet::Compiler::NodeKind::Struct, Facet::Compiler::NodeKind::Enum}.includes?(candidate.kind)
      end
      owner_name = owner.try { |value| facet_enclosing_type_name_for(value) }
      name.includes?("::") || owner_name.nil? ? name : "#{owner_name}::#{name}"
    end

    private def facet_definition_class_method?(node : Facet::Compiler::SyntaxNode) : Bool
      name = node.name_node
      !!(name && {Facet::Compiler::NodeKind::Path, Facet::Compiler::NodeKind::Binary}.includes?(name.kind))
    end

    private def facet_declaration_node?(node : Facet::Compiler::SyntaxNode) : Bool
      {
        Facet::Compiler::NodeKind::Def,
        Facet::Compiler::NodeKind::Fun,
        Facet::Compiler::NodeKind::Class,
        Facet::Compiler::NodeKind::Module,
        Facet::Compiler::NodeKind::Struct,
        Facet::Compiler::NodeKind::Enum,
        Facet::Compiler::NodeKind::Lib,
        Facet::Compiler::NodeKind::Alias,
        Facet::Compiler::NodeKind::TypeDef,
        Facet::Compiler::NodeKind::AnnotationDef,
      }.includes?(node.kind)
    end

    private def facet_terminal_name(node : Facet::Compiler::SyntaxNode?) : Facet::Compiler::SyntaxNode?
      return nil unless node
      current = node
      while {Facet::Compiler::NodeKind::Path, Facet::Compiler::NodeKind::Binary}.includes?(current.kind)
        current = current.children.last
      end
      current = current.child(0) || current if current.kind == Facet::Compiler::NodeKind::TypeApply
      current
    end

    private def facet_terminal_name_span(node : Facet::Compiler::SyntaxNode?) : Facet::Compiler::Span?
      facet_terminal_name(node).try(&.name_span)
    end

    private def add_facet_occurrence(
      occurrences : Array(FacetOccurrence),
      seen : Set(String),
      uri : String,
      node : Facet::Compiler::SyntaxNode,
      span : Facet::Compiler::Span? = nil,
    ) : Nil
      target = span || node.name_span || node.span
      range = facet_range(node.tree, target)
      key = "#{uri}:#{range.start_position.line}:#{range.start_position.character}:#{range.end_position.line}:#{range.end_position.character}"
      return if seen.includes?(key)
      seen << key
      occurrences << FacetOccurrence.new(uri, range)
    end
  end
end
