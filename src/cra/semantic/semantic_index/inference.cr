module CRA::Psi
  class SemanticIndex
    private def infer_type_ref(
      node : Crystal::ASTNode,
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?,
      depth : Int32 = 0
    ) : TypeRef?
      return nil if depth > 4

      if type_ref = type_ref_from_value(node)
        return type_ref
      end

      type_env : TypeEnv? = nil
      case node
      when Crystal::Var
        type_env ||= build_type_env(scope_def, scope_class, cursor)
        type_env.locals[node.name]?
      when Crystal::InstanceVar
        type_env ||= build_type_env(scope_def, scope_class, cursor)
        type_env.ivars[node.name]?
      when Crystal::ClassVar
        type_env ||= build_type_env(scope_def, scope_class, cursor)
        type_env.cvars[node.name]?
      when Crystal::Path, Crystal::Generic, Crystal::Metaclass, Crystal::Union, Crystal::Self
        type_ref_from_type(node)
      when Crystal::Call
        infer_type_ref_from_call(node, context, scope_def, scope_class, cursor, depth + 1)
      else
        nil
      end
    end

    private def infer_type_ref_from_call(
      call : Crystal::Call,
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?,
      depth : Int32
    ) : TypeRef?
      if call.name == "new"
        if obj = call.obj
          return type_ref_from_type(obj)
        end
      end

      receiver_type : TypeRef? = nil
      class_method = false

      if obj = call.obj
        class_method = obj.is_a?(Crystal::Path) || obj.is_a?(Crystal::Generic) || obj.is_a?(Crystal::Metaclass)
        class_method = scope_def && scope_def.receiver ? true : false if obj.is_a?(Crystal::Self)
        receiver_type = infer_type_ref(obj, context, scope_def, scope_class, cursor, depth + 1)
      elsif context
        receiver_type = TypeRef.named(context)
        class_method = scope_def && scope_def.receiver ? true : false
      end

      return nil unless receiver_type
      if call.name == "[]"
        if indexed = infer_index_return_type(receiver_type, call)
          return indexed
        end
      end
      owner = resolve_type_ref(receiver_type, context)
      return nil unless owner

      candidates = find_methods_with_ancestors(owner, call.name, class_method)
      return nil if candidates.empty?

      narrowed = filter_methods_by_arity_strict(candidates, call)
      candidates = narrowed unless narrowed.empty?

      method = candidates.find(&.return_type_ref) || candidates.first?
      return nil unless method
      infer_method_return_type(method, receiver_type)
    end

    private def infer_method_return_type(method : CRA::Psi::Method, receiver_type : TypeRef) : TypeRef?
      return nil unless return_ref = method.return_type_ref
      substitutions = type_vars_for_owner(method.owner, receiver_type)
      substitute_type_ref(return_ref, substitutions, receiver_type)
    end

    private def type_vars_for_owner(owner : PsiElement | Nil, receiver_type : TypeRef) : Hash(String, TypeRef)
      mapping = {} of String => TypeRef
      return mapping unless owner
      defs = @type_defs_by_name[owner.name]?
      return mapping unless defs
      type_vars = defs.values.first.type_vars
      return mapping if type_vars.empty? || receiver_type.args.empty?

      type_vars.each_with_index do |var, idx|
        arg = receiver_type.args[idx]?
        break unless arg
        mapping[var] = arg
      end
      mapping
    end

    private def substitute_type_ref(
      type_ref : TypeRef,
      substitutions : Hash(String, TypeRef),
      receiver_type : TypeRef
    ) : TypeRef
      if type_ref.union?
        types = type_ref.union_types.map { |member| substitute_type_ref(member, substitutions, receiver_type) }
        return TypeRef.union(types)
      end

      name = type_ref.name
      return receiver_type if name == "self"
      return substitutions[name] if name && substitutions[name]?
      return type_ref if type_ref.args.empty? || name.nil?

      args = type_ref.args.map { |arg| substitute_type_ref(arg, substitutions, receiver_type) }
      TypeRef.named(name, args)
    end

    private def nil_type?(type_ref : TypeRef) : Bool
      return false if type_ref.union?
      name = type_ref.name
      name == "Nil" || name == "::Nil"
    end

    private def infer_index_return_type(receiver_type : TypeRef, call : Crystal::Call) : TypeRef?
      if receiver_type.union?
        types = [] of TypeRef
        receiver_type.union_types.each do |member|
          if indexed = infer_index_return_type(member, call)
            types << indexed
          end
        end
        return nil if types.empty?
        return types.first if types.size == 1
        return TypeRef.union(types)
      end

      name = receiver_type.name
      return nil unless name
      base_name = name.starts_with?("::") ? name[2..] : name
      case base_name
      when "Array", "Slice", "StaticArray", "Deque"
        return nil if receiver_type.args.empty?
        return receiver_type if range_index?(call) || call.args.size > 1
        receiver_type.args.first?
      when "Hash"
        receiver_type.args[1]?
      else
        nil
      end
    end

    private def range_index?(call : Crystal::Call) : Bool
      call.args.any? { |arg| arg.is_a?(Crystal::RangeLiteral) }
    end

    # Resolves a type-like AST node to a known module/class.
    private def resolve_type_node(node : Crystal::ASTNode, context : String?) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      case node
      when Crystal::Path
        resolve_path(node, context) || resolve_alias_target(node.full, context)
      when Crystal::Generic
        resolve_type_node(node.name, context)
      when Crystal::Metaclass
        resolve_type_node(node.name, context)
      when Crystal::Union
        node.types.each do |type|
          if resolved = resolve_type_node(type, context)
            return resolved
          end
        end
        nil
      else
        nil
      end
    end

    private def resolve_enum_member(path : Crystal::Path, context : String?) : CRA::Psi::EnumMember?
      names = path.names
      return nil if names.empty?

      if names.size == 1
        if context_enum = resolve_enum(context)
          return context_enum.members.find { |member| member.name == names.first }
        end
        return nil
      end

      member_name = names.last
      enum_name = names[0...-1].join("::")
      enum_type = path.global? ? find_enum(enum_name) : resolve_enum(enum_name, context)
      return nil unless enum_type
      enum_type.members.find { |member| member.name == member_name }
    end

    private def resolve_enum(name : String?) : CRA::Psi::Enum?
      return nil unless name && !name.empty?
      if context = name
        if enum_type = find_enum(context)
          return enum_type
        end
      end
      nil
    end

    private def resolve_enum(name : String, context : String?) : CRA::Psi::Enum?
      if context && !context.empty?
        parts = context.split("::")
        while parts.size > 0
          candidate = (parts + [name]).join("::")
          if resolved = find_enum(candidate)
            return resolved
          end
          parts.pop
        end
      end
      find_enum(name)
    end

    def dump_roots
      @roots.each do |root|
        dump_element(root, 0)
      end
    end

    def dump_element(element : PsiElement, indent : Int32)
      indentation = "  " * indent
      Log.info { "#{indentation}- #{element.class.name}: #{element.name} (file: #{element.file})" }
      case element
      when Module
        element.classes.each do |cls|
          dump_element(cls, indent + 1)
        end
        element.methods.each do |meth|
          dump_element(meth, indent + 1)
        end
      when Class
        element.methods.each do |meth|
          dump_element(meth, indent + 1)
        end
      when Enum
        element.members.each do |member|
          dump_element(member, indent + 1)
        end
        element.methods.each do |meth|
          dump_element(meth, indent + 1)
        end
      end
    end

    private def resolve_path(path : Crystal::Path, context : String?) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      name = path.full
      return find_type(name) if path.global?
      resolve_in_context(name, context)
    end

    private def resolve_in_context(name : String, context : String?) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      if context && !context.empty?
        parts = context.split("::")
        while parts.size > 0
          candidate = (parts + [name]).join("::")
          if resolved = find_type(candidate)
            return resolved
          end
          parts.pop
        end
      end
      find_type(name)
    end

    private def resolve_alias_target(name : String, context : String?) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      if alias_def = resolve_alias_in_context(name, context)
        if target = alias_def.target
          return resolve_type_ref(target, context)
        end
      end
      nil
    end
  end
end
