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
  end
end
