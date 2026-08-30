module CRA::Psi
  class SemanticIndex
    def facet_signature_methods(
      call : Facet::Compiler::SyntaxNode,
      node_path : Array(Facet::Compiler::SyntaxNode),
      cursor_offset : Int32,
      context : String? = nil,
      current_file : String? = nil,
    ) : Array(Method)
      semantic_context = FacetSemanticContext.new(node_path, cursor_offset, context, current_file)
      facet_signature_help_methods(call, semantic_context)
    end

    def find_facet_definitions(
      node : Facet::Compiler::SyntaxNode,
      node_path : Array(Facet::Compiler::SyntaxNode),
      cursor_offset : Int32,
      context : String? = nil,
      current_file : String? = nil,
    ) : Array(PsiElement)
      semantic_context = FacetSemanticContext.new(node_path, cursor_offset, context, current_file)
      results = [] of PsiElement

      case node.kind
      when Facet::Compiler::NodeKind::Class, Facet::Compiler::NodeKind::Module,
           Facet::Compiler::NodeKind::Struct, Facet::Compiler::NodeKind::Enum,
           Facet::Compiler::NodeKind::Lib
        name = context || node.name
        results.concat(facet_type_elements(name)) if name
      when Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Fun
        if context && (owner = find_type(context)) && (name = node.name)
          results.concat(find_methods_with_ancestors(owner, facet_method_name(node, name), facet_class_method?(node)))
        end
      when Facet::Compiler::NodeKind::Param, Facet::Compiler::NodeKind::Splat,
           Facet::Compiler::NodeKind::DoubleSplat, Facet::Compiler::NodeKind::BlockParam
        if name = node.name
          results << facet_local_element(node, name, current_file)
        end
      when Facet::Compiler::NodeKind::InstanceVar
        results.concat(facet_scoped_variable_definition(node, semantic_context, false))
      when Facet::Compiler::NodeKind::ClassVar
        results.concat(facet_scoped_variable_definition(node, semantic_context, true))
      when Facet::Compiler::NodeKind::Call, Facet::Compiler::NodeKind::CallWithBlock,
           Facet::Compiler::NodeKind::Binary
        if node.call_name
          methods = facet_signature_help_methods(node, semantic_context)
          narrowed = filter_facet_methods_by_arity(methods, node.arguments.size)
          results.concat(narrowed.empty? ? methods : narrowed)
        else
          results.concat(facet_named_definition(node, semantic_context))
        end
      when Facet::Compiler::NodeKind::NamedArg
        if call = facet_call_around(node_path)
          methods = facet_signature_help_methods(call, semantic_context)
          narrowed = filter_facet_methods_by_arity(methods, call.arguments.size)
          results.concat(narrowed.empty? ? methods : narrowed)
        end
      when Facet::Compiler::NodeKind::Alias, Facet::Compiler::NodeKind::TypeDef
        if name = node.name
          if alias_definition = resolve_alias_in_context(name, context, current_file)
            results << alias_definition
          end
        end
      else
        results.concat(facet_named_definition(node, semantic_context))
      end

      dedupe_facet_elements(results)
    end

    def find_facet_declarations(
      node : Facet::Compiler::SyntaxNode,
      node_path : Array(Facet::Compiler::SyntaxNode),
      cursor_offset : Int32,
      context : String? = nil,
      current_file : String? = nil,
    ) : Array(PsiElement)
      find_facet_definitions(node, node_path, cursor_offset, context, current_file)
    end

    def find_facet_type_definitions(
      node : Facet::Compiler::SyntaxNode,
      node_path : Array(Facet::Compiler::SyntaxNode),
      cursor_offset : Int32,
      context : String? = nil,
      current_file : String? = nil,
    ) : Array(PsiElement)
      semantic_context = FacetSemanticContext.new(node_path, cursor_offset, context, current_file)
      if member = resolve_facet_enum_member(node.symbol_name, context)
        return facet_type_elements(member.owner.name)
      end

      refs = facet_type_refs_for_node(node, semantic_context)
      results = [] of PsiElement
      refs.each do |type_ref|
        results.concat(type_definition_elements_for(type_ref, context, current_file))
      end
      dedupe_facet_elements(results)
    end

    def find_facet_implementations(
      node : Facet::Compiler::SyntaxNode,
      node_path : Array(Facet::Compiler::SyntaxNode),
      cursor_offset : Int32,
      context : String? = nil,
      current_file : String? = nil,
    ) : Array(PsiElement)
      definitions = find_facet_definitions(node, node_path, cursor_offset, context, current_file)
      results = [] of PsiElement
      definitions.each do |definition|
        case definition
        when Method
          results.concat(method_implementations(definition))
        when Class, Module
          results.concat(implementers_for_type(definition))
        end
      end
      dedupe_facet_elements(results)
    end

    private def facet_named_definition(
      node : Facet::Compiler::SyntaxNode,
      context : FacetSemanticContext,
    ) : Array(PsiElement)
      name = node.symbol_name || node.name
      return [] of PsiElement unless name && !name.empty?

      if name == "self"
        return context.enclosing_type_name.try { |type_name| facet_type_elements(type_name) } || [] of PsiElement
      end

      if {Facet::Compiler::NodeKind::Ident, Facet::Compiler::NodeKind::InstanceVar,
          Facet::Compiler::NodeKind::ClassVar}.includes?(node.kind) && !name[0].ascii_uppercase?
        if definition = facet_local_definition(context, name)
          return [facet_local_element(definition, name, context.current_file)] of PsiElement
        end
        if type_name = context.enclosing_type_name
          if owner = find_type(type_name)
            methods = find_methods_with_ancestors(owner, name, facet_class_method?(context.enclosing_def))
            zero_arity = filter_facet_methods_by_arity(methods, 0)
            unless methods.empty?
              selected = zero_arity.empty? ? methods : zero_arity
              return selected.map { |method| method.as(PsiElement) }
            end
          end
        end
      end

      if alias_definition = resolve_alias_in_context(name, context.enclosing_type_name, context.current_file)
        return [alias_definition] of PsiElement
      end
      if enum_member = resolve_facet_enum_member(name, context.enclosing_type_name)
        return [enum_member] of PsiElement
      end
      facet_type_elements_for_name(name, context.enclosing_type_name)
    end

    private def facet_type_elements(name : String?) : Array(PsiElement)
      return [] of PsiElement unless name
      normalized = name.lchop("::")
      definitions = type_definition_elements(normalized)
      return definitions unless definitions.empty?
      find_type(normalized).try { |type| [type] of PsiElement } || [] of PsiElement
    end

    private def facet_type_elements_for_name(name : String, context : String?) : Array(PsiElement)
      if resolved = resolve_type_name(name, context)
        return facet_type_elements(resolved.name)
      end
      [] of PsiElement
    end

    private def resolve_facet_enum_member(name : String?, context : String?) : EnumMember?
      return nil unless name && !name.empty?
      normalized = name.lchop("::")
      parts = normalized.split("::")
      if parts.size == 1
        return find_enum(context).try(&.members.find { |member| member.name == parts.first }) if context
        return nil
      end

      member_name = parts.last
      enum_name = parts[0...-1].join("::")
      enum_type = name.starts_with?("::") ? find_enum(enum_name) : resolve_enum(enum_name, context)
      enum_type.try(&.members.find { |member| member.name == member_name })
    end

    private def facet_local_definition(context : FacetSemanticContext, name : String) : Facet::Compiler::SyntaxNode?
      definition = context.enclosing_def
      return nil unless definition

      best = definition.parameters.find { |parameter| parameter.name == name }
      context.node_path.reverse_each do |candidate|
        next unless {Facet::Compiler::NodeKind::Block, Facet::Compiler::NodeKind::CallWithBlock}.includes?(candidate.kind)
        if parameter = candidate.parameters.find { |value| value.name == name }
          best = parameter
          break
        end
      end

      if body = definition.body
        if assigned = latest_facet_assignment(body, name, Facet::Compiler::NodeKind::Ident, context.cursor_offset, true)
          best = assigned if best.nil? || assigned.span.start >= best.not_nil!.span.start
        end
      end
      best
    end

    private def facet_scoped_variable_definition(
      node : Facet::Compiler::SyntaxNode,
      context : FacetSemanticContext,
      class_variable : Bool,
    ) : Array(PsiElement)
      name = node.symbol_name
      type_name = context.enclosing_type_name
      type_node = context.enclosing_type
      return [] of PsiElement unless name && type_name && type_node
      kind = class_variable ? Facet::Compiler::NodeKind::ClassVar : Facet::Compiler::NodeKind::InstanceVar

      definition = context.enclosing_def.try(&.body).try do |body|
        latest_facet_assignment(body, name, kind, context.cursor_offset, true)
      end
      definition ||= type_node.body.try do |body|
        latest_facet_assignment(body, name, kind, Int32::MAX, false)
      end
      return [] of PsiElement unless definition
      owner = find_class(type_name)
      return [] of PsiElement unless owner

      env = build_facet_type_env(context)
      type_ref = class_variable ? env.cvars[name]? : env.ivars[name]?
      location = facet_location_for(definition, true)
      if class_variable
        [ClassVar.new(context.current_file, name, type_ref.try(&.display) || "Unknown", owner, location)] of PsiElement
      else
        [InstanceVar.new(context.current_file, name, type_ref.try(&.display) || "Unknown", owner, location)] of PsiElement
      end
    end

    private def latest_facet_assignment(
      node : Facet::Compiler::SyntaxNode,
      name : String,
      kind : Facet::Compiler::NodeKind,
      cursor_offset : Int32,
      skip_nested_defs : Bool,
    ) : Facet::Compiler::SyntaxNode?
      return nil if node.span.start > cursor_offset
      return nil if {
                      Facet::Compiler::NodeKind::Class,
                      Facet::Compiler::NodeKind::Module,
                      Facet::Compiler::NodeKind::Struct,
                      Facet::Compiler::NodeKind::Enum,
                      Facet::Compiler::NodeKind::Lib,
                      Facet::Compiler::NodeKind::MacroDef,
                    }.includes?(node.kind)
      return nil if skip_nested_defs && {Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Fun}.includes?(node.kind)

      best = nil.as(Facet::Compiler::SyntaxNode?)
      if node.kind == Facet::Compiler::NodeKind::Param && node.name == name
        name_node = node.name_node
        best = node if name_node && name_node.kind == kind
      elsif target = node.target
        best = target if target.kind == kind && target.symbol_name == name
      end

      node.children.each do |child|
        candidate = latest_facet_assignment(child, name, kind, cursor_offset, skip_nested_defs)
        next unless candidate
        best = candidate if best.nil? || candidate.span.start >= best.not_nil!.span.start
      end
      best
    end

    private def facet_local_element(
      node : Facet::Compiler::SyntaxNode,
      name : String,
      current_file : String?,
    ) : LocalVar
      LocalVar.new(current_file, name, location: facet_location_for(node, true))
    end

    private def facet_location_for(node : Facet::Compiler::SyntaxNode, name_only : Bool = false) : Location
      span = name_only ? (node.name_span || node.span) : node.span
      start_position = node.tree.position_at(span.start)
      end_position = node.tree.position_at(span.finish)
      Location.new(start_position.line, start_position.character, end_position.line, end_position.character)
    end

    private def facet_type_refs_for_node(
      node : Facet::Compiler::SyntaxNode,
      context : FacetSemanticContext,
    ) : Array(TypeRef)
      type_ref = case node.kind
                 when Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Fun
                   node.return_type.try { |value| type_ref_from_facet(value) }
                 when Facet::Compiler::NodeKind::Param, Facet::Compiler::NodeKind::Splat,
                      Facet::Compiler::NodeKind::DoubleSplat, Facet::Compiler::NodeKind::BlockParam
                   node.declared_type.try { |value| type_ref_from_facet(value) }
                 else
                   infer_facet_type_ref(node, context.enclosing_type_name, build_facet_type_env(context))
                 end
      return [] of TypeRef unless type_ref
      refs = [] of TypeRef
      collect_type_refs(type_ref, refs)
      refs
    end

    private def facet_call_around(path : Array(Facet::Compiler::SyntaxNode)) : Facet::Compiler::SyntaxNode?
      path.reverse_each.find { |candidate| candidate.receiver && candidate.call_name } ||
        path.reverse_each.find { |candidate| candidate.call_name }
    end

    private def facet_method_name(node : Facet::Compiler::SyntaxNode, fallback : String) : String
      name = node.name_node
      return fallback unless name
      while {Facet::Compiler::NodeKind::Path, Facet::Compiler::NodeKind::Binary}.includes?(name.kind)
        name = name.children.last
      end
      name.symbol_name || fallback
    end

    private def dedupe_facet_elements(elements : Array(PsiElement)) : Array(PsiElement)
      seen = Set(String).new
      elements.select do |element|
        location = element.location
        key = "#{element.class}:#{element.name}:#{element.file}:#{location.try(&.start_line)}:#{location.try(&.start_character)}"
        !seen.includes?(key).tap { |fresh| seen << key if fresh }
      end
    end
  end
end
