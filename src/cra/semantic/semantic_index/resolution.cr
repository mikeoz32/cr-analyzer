module CRA::Psi
  class SemanticIndex
    private def call_arity(call : Crystal::Call) : Int32
      call.args.size + (call.named_args.try(&.size) || 0)
    end

    private def arity_match?(method : Method, arity : Int32) : Bool
      return false if arity < method.min_arity
      max = method.max_arity
      return true if max.nil?
      arity <= max
    end

    private def filter_methods_by_arity(methods : Array(Method), call : Crystal::Call) : Array(Method)
      call_arity = call_arity(call)
      matches = methods.select { |method| arity_match?(method, call_arity) }
      matches.empty? ? methods : matches
    end

    private def filter_methods_by_arity_strict(methods : Array(Method), call : Crystal::Call) : Array(Method)
      call_arity = call_arity(call)
      methods.select { |method| arity_match?(method, call_arity) }
    end

    # Search in owner, then included modules and superclasses (depth-first).
    private def find_methods_with_ancestors(owner : CRA::Psi::PsiElement, name : String, class_method : Bool? = nil) : Array(Method)
      find_methods_with_ancestors(owner, name, class_method, {} of String => Bool)
    end

    private def find_methods_with_ancestors(owner : CRA::Psi::PsiElement, name : String, class_method : Bool?, visited : Hash(String, Bool)) : Array(Method)
      return [] of CRA::Psi::Method unless owner.is_a?(CRA::Psi::Module) || owner.is_a?(CRA::Psi::Class) || owner.is_a?(CRA::Psi::Enum)

      owner_name = owner.name
      return [] of CRA::Psi::Method if visited[owner_name]?
      visited[owner_name] = true

      results = find_methods_in(owner, name, class_method)
      case owner
      when CRA::Psi::Class
        if class_method != true
          if includes = @class_includes[owner_name]?
            includes.each do |inc|
              if resolved = resolve_type_node(inc, owner_name)
                results.concat(find_methods_with_ancestors(resolved, name, class_method, visited))
              end
            end
          end
        end
        if super_node = @class_superclass[owner_name]?
          if resolved = resolve_type_node(super_node, owner_name)
            results.concat(find_methods_with_ancestors(resolved, name, class_method, visited))
          end
        else
          # Crystal classes implicitly inherit from Reference/Object; pull their methods when no explicit superclass is set.
          if default_super = find_type("Reference") || find_type("Object")
            results.concat(find_methods_with_ancestors(default_super, name, class_method, visited))
          end
        end
      when CRA::Psi::Module
        if class_method != true
          if includes = @module_includes[owner_name]?
            includes.each do |inc|
              if resolved = resolve_type_node(inc, owner_name)
                results.concat(find_methods_with_ancestors(resolved, name, class_method, visited))
              end
            end
          end
        end
      when CRA::Psi::Enum
      end
      results
    end

    # Resolves definitions with a small local type env when receivers are not paths.
    def find_definitions(
      node : Crystal::ASTNode,
      context : String? = nil,
      scope_def : Crystal::Def? = nil,
      scope_class : Crystal::ClassDef? = nil,
      cursor : Crystal::Location? = nil,
      current_file : String? = nil
    ) : Array(PsiElement)
      results = [] of PsiElement
      type_env : TypeEnv? = nil
      case node
      when Crystal::Union
        type_refs = type_refs_for_node(node, context, scope_def, scope_class, cursor)
        type_refs.each do |type_ref|
          results.concat(type_definition_elements_for(type_ref, context, current_file))
        end
      when Crystal::ModuleDef
        if resolved = resolve_path(node.name, context)
          results << resolved
        end
      when Crystal::ClassDef
        if resolved = resolve_path(node.name, context)
          results << resolved
        end
      when Crystal::Def
        if context && (owner = find_type(context))
          results.concat(find_methods_with_ancestors(owner, node.name))
        end
      when Crystal::Var
        if scope_def
          if def_node = local_definition(scope_def, node.name, cursor)
            file = current_file || @current_file
            results << CRA::Psi::LocalVar.new(
              file: file,
              name: node.name,
              location: location_for(def_node)
            )
          end
        end
      when Crystal::InstanceVar
        if def_node = instance_var_definition(scope_def, scope_class, node.name, cursor)
          file = current_file || @current_file
          type_env ||= build_type_env(scope_def, scope_class, cursor)
          ivar_type = type_env.ivars[node.name]?.try(&.display) || "Unknown"
          if context && (owner = find_class(context))
            results << CRA::Psi::InstanceVar.new(
              file: file,
              name: node.name,
              type: ivar_type,
              owner: owner,
              location: location_for(def_node)
            )
          else
            results << CRA::Psi::LocalVar.new(
              file: file,
              name: node.name,
              location: location_for(def_node)
            )
          end
        end
      when Crystal::Call
        candidates = [] of CRA::Psi::Method
        if obj = node.obj
          case obj
          when Crystal::Self
            if context && (owner = find_type(context))
              in_class_method = scope_def && scope_def.receiver
              candidates.concat(find_methods_with_ancestors(owner, node.name, in_class_method ? true : false))
            end
          when Crystal::Path, Crystal::Generic, Crystal::Metaclass
            if owner = resolve_type_node(obj, context)
              if node.name == "new"
                candidates.concat(resolve_constructor(owner, node, context))
              else
                candidates.concat(find_methods_with_ancestors(owner, node.name, true))
              end
            end
          when Crystal::Var
            type_env ||= build_type_env(scope_def, scope_class, cursor)
            if type_ref = type_env.locals[obj.name]?
              if owner = resolve_type_ref(type_ref, context)
                candidates.concat(find_methods_with_ancestors(owner, node.name, false))
              end
            end
          when Crystal::InstanceVar
            type_env ||= build_type_env(scope_def, scope_class, cursor)
            if type_ref = type_env.ivars[obj.name]?
              if owner = resolve_type_ref(type_ref, context)
                candidates.concat(find_methods_with_ancestors(owner, node.name, false))
              end
            end
          when Crystal::ClassVar
            type_env ||= build_type_env(scope_def, scope_class, cursor)
            if type_ref = type_env.cvars[obj.name]?
              if owner = resolve_type_ref(type_ref, context)
                candidates.concat(find_methods_with_ancestors(owner, node.name, false))
              end
            end
          else
            if type_ref = infer_type_ref(obj, context, scope_def, scope_class, cursor)
              if owner = resolve_type_ref(type_ref, context)
                candidates.concat(find_methods_with_ancestors(owner, node.name, false))
              end
            end
          end
        elsif context && (owner = find_type(context))
          in_class_method = scope_def && scope_def.receiver
          candidates.concat(find_methods_with_ancestors(owner, node.name, in_class_method ? true : false))
        end
        unless candidates.empty?
          results.concat(filter_methods_by_arity(candidates, node))
        end
      when Crystal::Path
        Log.info { "Finding definitions for Path node: #{node.names.to_s} #{node.to_s}" }
        if alias_def = resolve_alias_in_context(node.full, context, current_file)
          results << alias_def
        elsif member = resolve_enum_member(node, context)
          results << member
        elsif resolved = resolve_type_node(node, context)
          defs = type_definition_elements(resolved.name)
          if defs.empty?
            results << resolved
          else
            results.concat(defs)
          end
        end
      when Crystal::Generic
        if alias_name = node.name.as?(Crystal::Path)
          if alias_def = resolve_alias_in_context(alias_name.full, context, current_file)
            results << alias_def
            return results
          end
        end
        if resolved = resolve_type_node(node, context)
          defs = type_definition_elements(resolved.name)
          if defs.empty?
            results << resolved
          else
            results.concat(defs)
          end
        end
      end
      results
    end

    # Declaration is currently the same as definition for the lightweight index.
    def find_declarations(
      node : Crystal::ASTNode,
      context : String? = nil,
      scope_def : Crystal::Def? = nil,
      scope_class : Crystal::ClassDef? = nil,
      cursor : Crystal::Location? = nil,
      current_file : String? = nil
    ) : Array(PsiElement)
      find_definitions(node, context, scope_def, scope_class, cursor, current_file)
    end

    # Resolves type definitions for variables/calls based on lightweight inference.
    def find_type_definitions(
      node : Crystal::ASTNode,
      context : String? = nil,
      scope_def : Crystal::Def? = nil,
      scope_class : Crystal::ClassDef? = nil,
      cursor : Crystal::Location? = nil,
      current_file : String? = nil
    ) : Array(PsiElement)
      if node.is_a?(Crystal::Path)
        if member = resolve_enum_member(node, context)
          return type_definition_elements(member.owner.name)
        end
      end

      type_refs = type_refs_for_node(node, context, scope_def, scope_class, cursor)
      return [] of PsiElement if type_refs.empty?

      results = [] of PsiElement
      type_refs.each do |type_ref|
        results.concat(type_definition_elements_for(type_ref, context, current_file))
      end
      results
    end

    # Finds implementations of types/methods via includes and subclass relationships.
    def find_implementations(
      node : Crystal::ASTNode,
      context : String? = nil,
      scope_def : Crystal::Def? = nil,
      scope_class : Crystal::ClassDef? = nil,
      cursor : Crystal::Location? = nil,
      current_file : String? = nil
    ) : Array(PsiElement)
      case node
      when Crystal::Path, Crystal::Generic, Crystal::Metaclass
        if resolved = resolve_type_node(node, context)
          return implementers_for_type(resolved)
        end
      end

      results = [] of PsiElement
      definitions = find_definitions(node, context, scope_def, scope_class, cursor, current_file)
      call = node.as?(Crystal::Call)
      definitions.each do |definition|
        case definition
        when Method
          results.concat(method_implementations(definition, call))
        when Class, Module
          results.concat(implementers_for_type(definition))
        end
      end
      results
    end

    # Public resolver for diagnostics and workspace features that need best-effort type lookup.
    def resolve_type_for(
      name : String,
      context : String? = nil,
      file : String? = nil
    ) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      canonical = canonical_name(name)

      if name.starts_with?("::")
        if resolved = find_type(canonical)
          return resolved
        end
      else
        if resolved = resolve_in_context(canonical, context)
          return resolved
        end
      end

      if alias_def = resolve_alias_in_context(canonical, context, file)
        if target = alias_def.target
          return resolve_type_ref(target, context)
        end
      end

      nil
    end

    def resolve_enum_for(name : String, context : String? = nil, global : Bool = false) : CRA::Psi::Enum?
      canonical = canonical_name(name)
      return find_enum(canonical) if global || name.starts_with?("::")
      resolve_enum(canonical, context)
    end

    private def type_refs_for_node(
      node : Crystal::ASTNode,
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?
    ) : Array(TypeRef)
      refs = [] of TypeRef
      case node
      when Crystal::Def
        if return_type = node.return_type
          if type_ref = type_ref_from_type(return_type)
            refs << type_ref
          end
        end
      when Crystal::Arg
        if restriction = node.restriction
          if type_ref = type_ref_from_type(restriction)
            refs << type_ref
          end
        end
      when Crystal::TypeDeclaration
        if type_ref = type_ref_from_type(node.declared_type)
          refs << type_ref
        end
      when Crystal::Union
        node.types.each do |type|
          if type_ref = type_ref_from_type(type)
            refs << type_ref
          end
        end
      end

      if refs.empty?
        if type_ref = infer_type_ref(node, context, scope_def, scope_class, cursor)
          refs << type_ref
        end
      end

      flattened = [] of TypeRef
      refs.each { |ref| collect_type_refs(ref, flattened) }
      flattened
    end

    private def collect_type_refs(type_ref : TypeRef, results : Array(TypeRef))
      if type_ref.union?
        type_ref.union_types.each do |member|
          collect_type_refs(member, results)
        end
        return
      end
      results << type_ref
    end

    private def type_definition_elements_for(
      type_ref : TypeRef,
      context : String?,
      current_file : String?,
      depth : Int32 = 0
    ) : Array(PsiElement)
      return [] of PsiElement if depth > 6

      if type_ref.union?
        results = [] of PsiElement
        type_ref.union_types.each do |member|
          results.concat(type_definition_elements_for(member, context, current_file, depth + 1))
        end
        return results
      end

      name = type_ref.name
      return [] of PsiElement unless name
      name = context if name == "self" && context

      if name == "Nil" || name == "::Nil"
        if defs = type_definition_elements(name)
          return defs unless defs.empty?
        end
        return [CRA::Psi::PsiElement.new(nil, "Nil", nil)]
      end

      if resolved = resolve_type_name(name, context)
        defs = type_definition_elements(resolved.name)
        return defs.empty? ? [resolved] : defs
      end

      if alias_def = resolve_alias_in_context(name, context, current_file)
        if target = alias_def.target
          return type_definition_elements_for(target, context, current_file, depth + 1)
        end
        results = [] of PsiElement
        results << alias_def
        return results
      end

      [] of PsiElement
    end

    private def method_implementations(method : Method, call : Crystal::Call? = nil) : Array(Method)
      owner = method.owner
      return [] of Method unless owner

      results = [] of Method
      implementers_for_type(owner).each do |implementer|
        next unless implementer.is_a?(CRA::Psi::Module) || implementer.is_a?(CRA::Psi::Class) || implementer.is_a?(CRA::Psi::Enum)
        candidates = find_methods_in(implementer, method.name, method.class_method)
        candidates = filter_methods_by_arity(candidates, call) if call
        results.concat(candidates)
      end
      results
    end

    private def implementers_for_type(type : PsiElement) : Array(PsiElement)
      case type
      when Class
        subclasses_for(type.name)
      when Module
        includers_for(type.name)
      else
        [] of PsiElement
      end
    end

    private def subclasses_for(name : String) : Array(PsiElement)
      results = [] of PsiElement
      seen = {} of String => Bool
      queue = [name]
      idx = 0

      while idx < queue.size
        current = queue[idx]
        idx += 1
        @class_superclass.each do |child_name, super_node|
          next if seen[child_name]?
          resolved = resolve_type_node(super_node, child_name)
          next unless resolved && resolved.name == current

          if child = find_class(child_name)
            results << child
            seen[child_name] = true
            queue << child.name
          end
        end
      end
      results
    end

    private def includers_for(name : String) : Array(PsiElement)
      results = [] of PsiElement
      seen = {} of String => Bool
      queue = [name]
      idx = 0

      while idx < queue.size
        current = queue[idx]
        idx += 1

        @module_includes.each do |owner_name, includes|
          next if seen[owner_name]?
          next unless includes_type?(includes, owner_name, current)
          if mod = find_module(owner_name)
            results << mod
            seen[owner_name] = true
            queue << mod.name
          end
        end

        @class_includes.each do |owner_name, includes|
          next if seen[owner_name]?
          next unless includes_type?(includes, owner_name, current)
          if cls = find_class(owner_name)
            results << cls
            seen[owner_name] = true
          end
        end
      end

      results
    end

    private def includes_type?(
      includes : Array(Crystal::ASTNode),
      owner_name : String,
      target_name : String
    ) : Bool
      includes.any? do |inc|
        resolved = resolve_type_node(inc, owner_name)
        resolved && resolved.name == target_name
      end
    end

    def signature_help_methods(
      call : Crystal::Call,
      context : String? = nil,
      scope_def : Crystal::Def? = nil,
      scope_class : Crystal::ClassDef? = nil,
      cursor : Crystal::Location? = nil
    ) : Array(Method)
      if obj = call.obj
        if (obj.is_a?(Crystal::Path) || obj.is_a?(Crystal::Generic) || obj.is_a?(Crystal::Metaclass)) && call.name == "new"
          if owner = resolve_type_node(obj, context)
            class_methods = find_methods_with_ancestors(owner, "new", true)
            return class_methods unless class_methods.empty?
            return find_methods_with_ancestors(owner, "initialize", false)
          end
        end

        if owner_info = resolve_receiver_owner(obj, context, scope_def, scope_class, cursor)
          owner, class_method = owner_info
          return find_methods_with_ancestors(owner, call.name, class_method)
        end
      elsif owner_info = resolve_receiver_owner(nil, context, scope_def, scope_class, cursor)
        owner, class_method = owner_info
        return find_methods_with_ancestors(owner, call.name, class_method)
      end

      [] of Method
    end

    # Cross-file references for types/aliases by name (best-effort; per-file path search).
    def references_for_path(name : String, context : String?, current_file : String?) : Array(CRA::Types::Location)
      locs = [] of CRA::Types::Location
      seen_files = {} of String => Bool

      each_candidate_name(name, context) do |candidate|
        if defs = @type_defs_by_name[candidate]?
          defs.each_key { |file| locs.concat(references_for_file(candidate, file, seen_files, current_file)) }
        end
        if aliases = @aliases_by_name[candidate]?
          aliases.each_key { |file| locs.concat(references_for_file(candidate, file, seen_files, current_file)) }
        end
      end

      locs
    end

    private def each_candidate_name(name : String, context : String?, &block : String ->)
      name = canonical_name(name)
      yield name
      if context && !context.empty?
        parts = context.split("::")
        while parts.size > 0
          candidate = (parts + [name]).join("::")
          yield candidate
          parts.pop
        end
      end
    end

    private def references_for_file(name : String, file : String, seen : Hash(String, Bool), current_file : String?) : Array(CRA::Types::Location)
      return [] of CRA::Types::Location if seen[file]?
      seen[file] = true
      path = URI.parse(file).path
      return [] of CRA::Types::Location unless File.exists?(path)

      source = File.read(path)
      parser = Crystal::Parser.new(source)
      parser.wants_doc = true
      program = parser.parse
      collector = CRA::PathHighlightCollector.new(name, name.starts_with?("::"))
      program.accept(collector)
      uri = file.starts_with?("file://") ? file : "file://#{file}"
      locations = [] of CRA::Types::Location
      collector.nodes.each do |node|
        if range = node_range_for_highlight(node, source)
          locations << CRA::Types::Location.new(uri: uri, range: range)
        end
      end
      locations
    rescue
      [] of CRA::Types::Location
    end

    private def node_range_for_highlight(node : Crystal::ASTNode, source : String) : CRA::Types::Range?
      if node.responds_to?(:name_size) && (loc = node.location)
        start_line = loc.line_number - 1
        start_char = loc.column_number - 1
        size = node.name_size
        end_char = start_char + size
        return CRA::Types::Range.new(
          start_position: CRA::Types::Position.new(line: start_line, character: start_char),
          end_position: CRA::Types::Position.new(line: start_line, character: end_char)
        )
      elsif loc = node.location
        end_loc = node.end_location || loc
        return CRA::Types::Range.new(
          start_position: CRA::Types::Position.new(line: loc.line_number - 1, character: loc.column_number - 1),
          end_position: CRA::Types::Position.new(line: end_loc.line_number - 1, character: end_loc.column_number)
        )
      end
      nil
    end
  end
end
