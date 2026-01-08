module CRA::Psi
  class SemanticIndex
    def complete(context : CRA::CompletionContext) : Array(CRA::Types::CompletionItem)
      return [] of CRA::Types::CompletionItem if context.require_prefix

      trigger = context.trigger_character
      case trigger
      when "."
        prefix = context.member_prefix(trigger)
        receiver = receiver_for_dot(context, prefix)
        return complete_members(context, prefix, receiver)
      when "::"
        namespace = namespace_completion_data(context).try(&.[](:namespace))
        return complete_namespace(context, context.member_prefix(trigger), namespace)
      when "@"
        return complete_instance_vars(context, context.member_prefix(trigger))
      end

      if data = namespace_completion_data(context)
        return complete_namespace(context, data[:prefix], data[:namespace])
      end

      if call = context.node.as?(Crystal::Call) || context.previous_node.as?(Crystal::Call)
        if receiver = call.obj
          return complete_members(context, context.word_prefix, receiver)
        end
      end

      complete_general(context)
    end

    private def add_include(store : Hash(String, Array(Crystal::ASTNode)), owner_name : String, include_node : Crystal::ASTNode)
      store[owner_name] ||= [] of Crystal::ASTNode
      store[owner_name] << include_node
    end

    # Builds a local type env from class-level declarations, initialize, and the current def.
    private def build_type_env(scope_def : Crystal::Def?, scope_class : Crystal::ClassDef?, cursor : Crystal::Location?) : TypeEnv
      env = TypeEnv.new
      if scope_class
        # Collect ivar declarations and assignments at class level.
        scope_class.body.accept(TypeCollector.new(env, nil, false))
        # Also consider ivars initialized in initialize.
        scope_class.body.accept(InitializeCollector.new(TypeCollector.new(env, nil, false)))
        # Fill missing ivars/cvars from other method bodies (best-effort).
        scope_class.body.accept(DefIvarCollector.new(TypeCollector.new(env, nil, false, true)))
      end
      if scope_def
        scope_def.args.each do |arg|
          if restriction = arg.restriction
            if type_ref = type_ref_from_type(restriction)
              env.locals[arg.name] = type_ref
            end
          end
        end
        scope_def.body.accept(TypeCollector.new(env, cursor, true))
      end
      env
    end

    private def complete_members(
      context : CRA::CompletionContext,
      prefix : String,
      receiver_node : Crystal::ASTNode? = nil
    ) : Array(CRA::Types::CompletionItem)
      receiver = receiver_node || receiver_node_for_completion(context.node) || receiver_node_for_completion(context.previous_node)
      return [] of CRA::Types::CompletionItem unless receiver

      owner_info = resolve_receiver_owner(
        receiver,
        context.enclosing_type_name,
        context.enclosing_def,
        context.enclosing_class,
        context.cursor_location
      )
      return [] of CRA::Types::CompletionItem unless owner_info

      owner, class_method = owner_info
      methods = methods_with_ancestors(owner, class_method)
      items = [] of CRA::Types::CompletionItem
      seen = {} of String => Bool
      methods.each do |method|
        next unless method.name.starts_with?(prefix)
        next if seen[method.name]?
        seen[method.name] = true
        items << CRA::Types::CompletionItem.new(
          label: method.name,
          kind: CRA::Types::CompletionItemKind::Method,
          detail: method_detail(method),
          data: completion_data(method_signature(method), method.doc)
        )
      end
      items
    end

    private def complete_namespace(
      context : CRA::CompletionContext,
      prefix : String,
      namespace_hint : String? = nil
    ) : Array(CRA::Types::CompletionItem)
      namespace = namespace_hint
      unless namespace
        if data = namespace_completion_data(context)
          namespace = data[:namespace]
          prefix = data[:prefix]
        end
      end
      return [] of CRA::Types::CompletionItem unless namespace

      resolved = resolve_type_name(namespace, context.enclosing_type_name)
      namespace_name = resolved.try(&.name) || namespace

      items = [] of CRA::Types::CompletionItem
      seen = {} of String => Bool

      if enum_type = resolved.as?(CRA::Psi::Enum)
        enum_type.members.each do |member|
          next unless member.name.starts_with?(prefix)
          next if seen[member.name]?
          seen[member.name] = true
          items << CRA::Types::CompletionItem.new(
            label: member.name,
            kind: CRA::Types::CompletionItemKind::EnumMember,
            detail: enum_type.name,
            data: completion_data("#{enum_type.name}::#{member.name}", member.doc)
          )
        end
      end

      type_candidates(namespace_name).each do |label, full_name|
        next unless label.starts_with?(prefix)
        next if seen[label]?
        seen[label] = true
        items << CRA::Types::CompletionItem.new(
          label: label,
          kind: completion_kind_for_type(full_name),
          detail: type_signature_for(full_name),
          data: completion_data(type_signature_line(full_name), type_doc_for(full_name))
        )
      end

      items
    end

    private def complete_instance_vars(context : CRA::CompletionContext, prefix : String) : Array(CRA::Types::CompletionItem)
      scope_class = context.enclosing_class
      return [] of CRA::Types::CompletionItem unless scope_class

      if prefix.starts_with?("@@")
        return complete_class_vars(scope_class, prefix, context)
      end

      collector = InstanceVarNameCollector.new
      scope_class.body.accept(collector)
      replace_range = replacement_range(context, prefix)
      items = [] of CRA::Types::CompletionItem
      seen = {} of String => Bool
      collector.names.each_key do |name|
        next unless name.starts_with?(prefix)
        next if seen[name]?
        seen[name] = true
        items << CRA::Types::CompletionItem.new(
          label: name,
          kind: CRA::Types::CompletionItemKind::Property,
          text_edit: CRA::Types::TextEdit.new(replace_range, name)
        )
      end
      items
    end

    private def complete_class_vars(
      scope_class : Crystal::ClassDef,
      prefix : String,
      context : CRA::CompletionContext
    ) : Array(CRA::Types::CompletionItem)
      collector = ClassVarNameCollector.new
      scope_class.body.accept(collector)
      replace_range = replacement_range(context, prefix)
      items = [] of CRA::Types::CompletionItem
      seen = {} of String => Bool
      collector.names.each_key do |name|
        next unless name.starts_with?(prefix)
        next if seen[name]?
        seen[name] = true
        items << CRA::Types::CompletionItem.new(
          label: name,
          kind: CRA::Types::CompletionItemKind::Variable,
          text_edit: CRA::Types::TextEdit.new(replace_range, name)
        )
      end
      items
    end

    private def complete_general(context : CRA::CompletionContext) : Array(CRA::Types::CompletionItem)
      prefix = context.word_prefix
      items = [] of CRA::Types::CompletionItem

      if prefix.starts_with?("@@")
        if scope_class = context.enclosing_class
          return complete_class_vars(scope_class, prefix, context)
        end
      elsif prefix.starts_with?("@")
        return complete_instance_vars(context, prefix)
      end

      if scope_def = context.enclosing_def
        local_definitions(scope_def, context.cursor_location).each_key do |name|
          next unless name.starts_with?(prefix)
          items << CRA::Types::CompletionItem.new(
            label: name,
            kind: CRA::Types::CompletionItemKind::Variable
          )
        end
      end

      namespace = parent_namespace(context.enclosing_type_name || "")
      type_candidates(namespace, include_global: true).each do |label, full_name|
        next unless label.starts_with?(prefix)
        items << CRA::Types::CompletionItem.new(
          label: label,
          kind: completion_kind_for_type(full_name),
          detail: type_signature_for(full_name),
          data: completion_data(type_signature_line(full_name), type_doc_for(full_name))
        )
      end

      items
    end

    private def type_candidates(namespace : String?, include_global : Bool = false) : Hash(String, String)
      results = {} of String => String
      if namespace && !namespace.empty?
        prefix = "#{namespace}::"
        @aliases_by_name.each_key do |name|
          next unless name.starts_with?(prefix)
          remainder = name[prefix.size..-1]? || ""
          next if remainder.empty?
          label = remainder.split("::").first
          full_name = "#{namespace}::#{label}"
          results[label] ||= full_name
        end
        @type_defs_by_name.each_key do |name|
          next unless name.starts_with?(prefix)
          remainder = name[prefix.size..-1]? || ""
          next if remainder.empty?
          label = remainder.split("::").first
          full_name = "#{namespace}::#{label}"
          results[label] ||= full_name
        end
      end

      if include_global || namespace.nil? || namespace.empty?
        @aliases_by_name.each_key do |name|
          next if name.includes?("::")
          results[name] ||= name
        end
        @type_defs_by_name.each_key do |name|
          next if name.includes?("::")
          results[name] ||= name
        end
      end
      results
    end

    private def completion_kind_for_type(full_name : String) : CRA::Types::CompletionItemKind
      if @aliases_by_name[full_name]?
        return CRA::Types::CompletionItemKind::Class
      end
      if defs = @type_defs_by_name[full_name]?
        kind = defs.values.first.kind
        return CRA::Types::CompletionItemKind::Module if kind == :module
        return CRA::Types::CompletionItemKind::Enum if kind == :enum
      end
      CRA::Types::CompletionItemKind::Class
    end

    def type_signature_for(full_name : String) : String
      if alias_def = find_alias(full_name)
        if target = alias_def.target
          return "alias #{full_name} = #{target.display}"
        end
        return "alias #{full_name}"
      end
      if defs = @type_defs_by_name[full_name]?
        type_vars = defs.values.first.type_vars
        return full_name if type_vars.empty?
        return "#{full_name}(#{type_vars.join(", ")})"
      end
      full_name
    end

    private def receiver_node_for_completion(
      node : Crystal::ASTNode?,
      prefer_call : Bool = false
    ) : Crystal::ASTNode?
      case node
      when Crystal::Call
        return node if prefer_call
        node.obj
      when Crystal::Var, Crystal::InstanceVar, Crystal::ClassVar, Crystal::Path, Crystal::Generic, Crystal::Metaclass, Crystal::Self
        node
      else
        nil
      end
    end

    private def receiver_for_dot(
      context : CRA::CompletionContext,
      prefix : String
    ) : Crystal::ASTNode?
      call = context.node.as?(Crystal::Call) || context.previous_node.as?(Crystal::Call)
      if call
        receiver = call.obj
        return receiver unless prefix.empty?

        if name_loc = call.name_location
          if cursor = context.cursor_location
            if location_before?(cursor, name_loc)
              return receiver
            end
          end
        end
        return call
      end

      receiver_node_for_completion(context.node) || receiver_node_for_completion(context.previous_node)
    end

    private def location_before?(left : Crystal::Location, right : Crystal::Location) : Bool
      left.line_number < right.line_number ||
        (left.line_number == right.line_number && left.column_number <= right.column_number)
    end

    private def resolve_receiver_owner(
      receiver : Crystal::ASTNode?,
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?
    ) : {CRA::Psi::PsiElement, Bool}?
      return nil unless receiver || context

      type_env : TypeEnv? = nil
      case receiver
      when Crystal::Self
        if context && (owner = find_type(context))
          in_class_method = scope_def && scope_def.receiver
          return {owner, in_class_method ? true : false}
        end
      when Crystal::Path, Crystal::Generic, Crystal::Metaclass
        if owner = resolve_type_node(receiver, context)
          return {owner, true}
        end
      when Crystal::Call
        if type_ref = infer_type_ref(receiver, context, scope_def, scope_class, cursor)
          if owner = resolve_type_ref(type_ref, context)
            return {owner, false}
          end
        end
      when Crystal::Var
        type_env ||= build_type_env(scope_def, scope_class, cursor)
        if type_ref = type_env.locals[receiver.name]?
          if owner = resolve_type_ref(type_ref, context)
            return {owner, false}
          end
        end
      when Crystal::InstanceVar
        type_env ||= build_type_env(scope_def, scope_class, cursor)
        if type_ref = type_env.ivars[receiver.name]?
          if owner = resolve_type_ref(type_ref, context)
            return {owner, false}
          end
        end
        if context && (owner = find_class(context))
          return {owner, false}
        end
      when Crystal::ClassVar
        type_env ||= build_type_env(scope_def, scope_class, cursor)
        if type_ref = type_env.cvars[receiver.name]?
          if owner = resolve_type_ref(type_ref, context)
            return {owner, true}
          end
        end
        if context && (owner = find_class(context))
          return {owner, true}
        end
      else
        if receiver
          if type_ref = infer_type_ref(receiver, context, scope_def, scope_class, cursor)
            if owner = resolve_type_ref(type_ref, context)
              return {owner, false}
            end
          end
        elsif context && (owner = find_type(context))
          in_class_method = scope_def && scope_def.receiver
          return {owner, in_class_method ? true : false}
        end
      end
      nil
    end

    private def methods_with_ancestors(
      owner : CRA::Psi::PsiElement,
      class_method : Bool?
    ) : Array(Method)
      results = [] of CRA::Psi::Method
      visited = {} of String => Bool
      collect_methods_with_ancestors(owner, class_method, visited, results)
      results
    end

    private def collect_methods_with_ancestors(
      owner : CRA::Psi::PsiElement,
      class_method : Bool?,
      visited : Hash(String, Bool),
      results : Array(Method)
    )
      return unless owner.is_a?(CRA::Psi::Module) || owner.is_a?(CRA::Psi::Class) || owner.is_a?(CRA::Psi::Enum)

      owner_name = owner.name
      return if visited[owner_name]?
      visited[owner_name] = true

      methods = owner.methods
      if class_method
        methods = methods.select(&.class_method)
      elsif class_method == false
        methods = methods.reject(&.class_method)
      end
      results.concat(methods)

      case owner
      when CRA::Psi::Class
        if class_method != true
          if includes = @class_includes[owner_name]?
            includes.each do |inc|
              if resolved = resolve_type_node(inc, owner_name)
                collect_methods_with_ancestors(resolved, class_method, visited, results)
              end
            end
          end
        end
        if super_node = @class_superclass[owner_name]?
          if resolved = resolve_type_node(super_node, owner_name)
            collect_methods_with_ancestors(resolved, class_method, visited, results)
          end
        end
      when CRA::Psi::Module
        if class_method != true
          if includes = @module_includes[owner_name]?
            includes.each do |inc|
              if resolved = resolve_type_node(inc, owner_name)
                collect_methods_with_ancestors(resolved, class_method, visited, results)
              end
            end
          end
        end
      when CRA::Psi::Enum
      end
    end

    private def method_detail(method : CRA::Psi::Method) : String
      owner_name = method.owner.try(&.name) || "self"
      arity = if max = method.max_arity
                "#{method.min_arity}..#{max}"
              else
                "#{method.min_arity}+"
              end
      "#{owner_name}#{method.class_method ? "." : "#"}#{method.name} (arity #{arity})"
    end

    private def method_signature(method : CRA::Psi::Method) : String
      owner_name = method.owner.try(&.name) || "self"
      separator = method.class_method ? "." : "#"
      params = method.parameters.join(", ")
      signature = "def #{owner_name}#{separator}#{method.name}"
      signature += "(#{params})" unless params.empty?
      if method.return_type_ref
        signature += " : #{method.return_type}"
      end
      signature
    end

    private def completion_data(signature : String?, doc : String?) : JSON::Any?
      signature = signature.try(&.strip)
      doc = doc.try(&.strip)
      return nil if (signature.nil? || signature.empty?) && (doc.nil? || doc.empty?)

      data = {} of String => JSON::Any
      if signature && !signature.empty?
        data["signature"] = JSON::Any.new(signature)
      end
      if doc && !doc.empty?
        data["doc"] = JSON::Any.new(doc)
      end
      JSON::Any.new(data)
    end

    private def type_signature_line(full_name : String) : String
      if @aliases_by_name[full_name]?
        return type_signature_for(full_name)
      end
      if defs = @type_defs_by_name[full_name]?
        kind = defs.values.first.kind
        prefix = kind == :module ? "module" : kind == :enum ? "enum" : "class"
        return "#{prefix} #{type_signature_for(full_name)}"
      end
      "class #{type_signature_for(full_name)}"
    end

    private def type_doc_for(full_name : String) : String?
      if alias_def = find_alias(full_name)
        return alias_def.doc
      end
      if element = find_type(full_name)
        return element.doc
      end
      nil
    end

    private def replacement_range(context : CRA::CompletionContext, prefix : String) : CRA::Types::Range
      position = context.request.position
      start_char = position.character - prefix.size
      start_char = 0 if start_char < 0
      CRA::Types::Range.new(
        start_position: CRA::Types::Position.new(line: position.line, character: start_char),
        end_position: CRA::Types::Position.new(line: position.line, character: position.character)
      )
    end

    private def local_definitions(scope_def : Crystal::Def, cursor : Crystal::Location?) : Hash(String, Crystal::ASTNode)
      definitions = {} of String => Crystal::ASTNode
      scope_def.args.each do |arg|
        definitions[arg.name] = arg
      end
      scope_def.body.accept(LocalVarCollector.new(definitions, cursor))
      definitions
    end

    private def resolve_type_name(name : String, context : String?) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      return find_type(name) if name.includes?("::")
      resolve_in_context(name, context)
    end

    private def namespace_completion_data(context : CRA::CompletionContext) : NamedTuple(namespace: String, prefix: String)?
      if match = context.line_prefix.match(/([A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)::([A-Za-z0-9_]*)$/)
        return {namespace: match[1], prefix: match[2]}
      end
      nil
    end

    private def local_definition(scope_def : Crystal::Def, name : String, cursor : Crystal::Location?) : Crystal::ASTNode?
      local_definitions(scope_def, cursor)[name]?
    end

    private def instance_var_definition(
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      name : String,
      cursor : Crystal::Location?
    ) : Crystal::ASTNode?
      if scope_def
        def_finder = InstanceVarDefinitionCollector.new(name, cursor, false)
        scope_def.body.accept(def_finder)
        return def_finder.definition if def_finder.definition
      end

      return nil unless scope_class

      class_finder = InstanceVarDefinitionCollector.new(name, nil, true)
      scope_class.body.accept(class_finder)
      class_finder.definition
    end

    private def resolve_constructor(owner : CRA::Psi::PsiElement, call : Crystal::Call, context : String?) : Array(Method)
      class_methods = find_methods_with_ancestors(owner, "new", true)
      class_matches = filter_methods_by_arity_strict(class_methods, call)
      return class_matches unless class_matches.empty?

      instance_inits = find_methods_with_ancestors(owner, "initialize", false)
      init_matches = filter_methods_by_arity_strict(instance_inits, call)
      return init_matches unless init_matches.empty?

      instance_inits
    end

    private def resolve_type_ref(type_ref : TypeRef, context : String?, depth : Int32 = 0) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      return nil if depth > 6
      if type_ref.union?
        type_ref.union_types.each do |member|
          next if nil_type?(member)
          if resolved = resolve_type_ref(member, context, depth + 1)
            return resolved
          end
        end
        return nil
      end

      name = type_ref.name
      return nil unless name
      return resolve_type_name(context, context) if name == "self" && context

      if resolved = resolve_type_name(name, context)
        return resolved
      end

      if alias_def = resolve_alias_in_context(name, context)
        if target = alias_def.target
          return resolve_type_ref(target, context, depth + 1)
        end
      end

      nil
    end

  end
end
