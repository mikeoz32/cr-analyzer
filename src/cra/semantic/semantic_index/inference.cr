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
      return nil if depth > 12

      if type_ref = type_ref_from_value(node)
        return type_ref
      end

      type_env : TypeEnv? = nil
      case node
      when Crystal::Var
        if node.name == "self" && context
          return TypeRef.named(context)
        end
        if scope_def
          # Fast path: check def args directly.
          scope_def.args.each do |arg|
            if arg.name == node.name
              if restriction = arg.restriction
                return type_ref_from_type(restriction)
              end
              return nil
            end
          end
          # Non-deep env handles ordered assignments and self-referential cases.
          type_env ||= build_type_env(scope_def, scope_class, cursor)
          if ref = type_env.locals[node.name]?
            return ref
          end
          # Fall back to assignment value inference for chains (e.g., ptr.value).
          if assign_val = find_local_assignment_value(scope_def, node.name, cursor)
            return infer_type_ref(assign_val, context, scope_def, scope_class, cursor, depth + 1)
          end
        end
        nil
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
      when Crystal::If
        infer_type_ref_from_if(node, context, scope_def, scope_class, cursor, depth + 1)
      when Crystal::Case
        infer_type_ref_from_case(node, context, scope_def, scope_class, cursor, depth + 1)
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
      if call.name == "new" || call.name == "null" || call.name == "malloc"
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
        if call.name == "class" && receiver_type
          return receiver_type
        end
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
      if pointee = infer_pointer_deref_type(receiver_type, call.name)
        return pointee
      end
      owner = resolve_type_ref(receiver_type, context)
      unless owner
        # For unresolved class method calls (e.g., Int64.from_io), assume the
        # return type is the receiver type since most class methods are factories.
        return receiver_type if class_method
        return nil
      end

      candidates = find_methods_with_ancestors(owner, call.name, class_method)
      if candidates.empty?
        if class_method && call.name == "[]"
          return infer_class_bracket_type(receiver_type, call)
        end
        # For class methods not in the index (e.g., stdlib), fall back to the
        # receiver type.
        return receiver_type if class_method
        return nil
      end

      narrowed = filter_methods_by_arity_strict(candidates, call)
      candidates = narrowed unless narrowed.empty?

      method = if call.block
                 candidates.find { |m| m.return_type_ref.nil? } || candidates.first?
               else
                 candidates.find(&.return_type_ref) || candidates.first?
               end
      return nil unless method
      result = infer_method_return_type(method, receiver_type, call, context, scope_def, scope_class, cursor, depth)
      if result.nil? && (block = call.block)
        result = infer_block_body_type(block, context, scope_def, scope_class, cursor, depth)
      end
      result
    end

    private def infer_type_ref_from_if(
      node : Crystal::If,
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?,
      depth : Int32
    ) : TypeRef?
      types = [] of TypeRef
      seen = Set(String).new

      # Collect the then branch type.
      if then_type = infer_branch_type(node.then, context, scope_def, scope_class, cursor, depth)
        types << then_type if seen.add?(then_type.display)
      end

      # Walk the elsif/else chain (Crystal models elsif as nested If in the else).
      else_node = node.else
      while else_node
        case else_node
        when Crystal::If
          if then_type = infer_branch_type(else_node.then, context, scope_def, scope_class, cursor, depth)
            types << then_type if seen.add?(then_type.display)
          end
          else_node = else_node.else
        when Crystal::Nop
          break
        else
          if else_type = infer_branch_type(else_node, context, scope_def, scope_class, cursor, depth)
            types << else_type if seen.add?(else_type.display)
          end
          break
        end
      end

      return nil if types.empty?
      return types.first if types.size == 1
      TypeRef.union(types)
    end

    private def infer_type_ref_from_case(
      node : Crystal::Case,
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?,
      depth : Int32
    ) : TypeRef?
      types = [] of TypeRef
      seen = Set(String).new

      node.whens.each do |wh|
        if wh_type = infer_branch_type(wh.body, context, scope_def, scope_class, cursor, depth)
          types << wh_type if seen.add?(wh_type.display)
        end
      end

      if else_body = node.else
        if else_type = infer_branch_type(else_body, context, scope_def, scope_class, cursor, depth)
          types << else_type if seen.add?(else_type.display)
        end
      end

      return nil if types.empty?
      return types.first if types.size == 1
      TypeRef.union(types)
    end

    # Infers the type of the last expression in a branch body, skipping
    # branches that always exit (raise, return, break, next).
    private def infer_branch_type(
      body : Crystal::ASTNode,
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?,
      depth : Int32
    ) : TypeRef?
      last = case body
             when Crystal::Expressions then body.expressions.last?
             when Crystal::Nop then return nil
             else body
             end
      return nil unless last
      return nil if branch_exits?(last)
      infer_type_ref(last, context, scope_def, scope_class, cursor, depth)
    end

    private def branch_exits?(node : Crystal::ASTNode) : Bool
      node.is_a?(Crystal::Return) || node.is_a?(Crystal::Break) || node.is_a?(Crystal::Next) ||
        (node.is_a?(Crystal::Call) && node.name == "raise")
    end

    # When a method has no return type and is called with a block,
    # infer the type from the block body's last expression.
    private def infer_block_body_type(
      block : Crystal::Block,
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?,
      depth : Int32
    ) : TypeRef?
      body = block.body
      return nil unless body
      last_expr = body.is_a?(Crystal::Expressions) ? body.expressions.last? : body
      return nil unless last_expr
      infer_type_ref(last_expr, context, scope_def, scope_class, cursor, depth + 1)
    end

    # Infers the return type of a class-level [] call (e.g., Slice[1u8, 2u8]).
    # These are typically macros that construct an instance of the receiver type.
    private def infer_class_bracket_type(receiver_type : TypeRef, call : Crystal::Call) : TypeRef?
      name = receiver_type.name
      return receiver_type unless name

      if first_arg = call.args.first?
        if elem_ref = type_ref_from_value(first_arg)
          return TypeRef.named(name, [elem_ref])
        end
      end

      receiver_type
    end

    private def infer_method_return_type(
      method : CRA::Psi::Method,
      receiver_type : TypeRef,
      call : Crystal::Call? = nil,
      context : String? = nil,
      scope_def : Crystal::Def? = nil,
      scope_class : Crystal::ClassDef? = nil,
      cursor : Crystal::Location? = nil,
      depth : Int32 = 0
    ) : TypeRef?
      return nil unless return_ref = method.return_type_ref
      substitutions = type_vars_for_owner(method.owner, receiver_type)
      if call
        infer_free_var_substitutions(method, call, substitutions, context, scope_def, scope_class, cursor, depth)
      end
      result = substitute_type_ref(return_ref, substitutions, receiver_type)
      owner_context = method.owner.try(&.name)
      qualify_type_ref(result, owner_context)
    end

    private def infer_free_var_substitutions(
      method : CRA::Psi::Method,
      call : Crystal::Call,
      substitutions : Hash(String, TypeRef),
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?,
      depth : Int32
    )
      type_var_names = method.free_vars.to_set
      if type_var_names.empty? && (return_ref = method.return_type_ref)
        collect_type_var_candidates(return_ref, method.param_type_refs, type_var_names, context)
      end
      return if type_var_names.empty?

      method.param_type_refs.each_with_index do |param_ref, idx|
        next unless param_ref
        name = param_ref.name
        next unless name
        next if substitutions[name]?
        next unless type_var_names.includes?(name)

        arg = call.args[idx]?
        next unless arg

        if arg_type = infer_type_ref(arg, context, scope_def, scope_class, cursor, depth + 1)
          substitutions[name] = arg_type
        end
      end

      if (block = call.block) && (block_ret_ref = method.block_return_type_ref)
        block_ret_name = block_ret_ref.name
        if block_ret_name && !substitutions[block_ret_name]? && type_var_names.includes?(block_ret_name)
          if body_type = infer_block_body_type(block, context, scope_def, scope_class, cursor, depth)
            substitutions[block_ret_name] = body_type
          end
        end
      end
    end

    private def collect_type_var_candidates(
      return_ref : TypeRef,
      param_type_refs : Array(TypeRef?),
      candidates : Set(String),
      context : String?
    )
      names = [] of String
      collect_type_ref_names(return_ref, names)
      names.each do |name|
        next if resolve_type_name(name, context)
        if param_type_refs.any? { |pr| pr && pr.name == name }
          candidates << name
        end
      end
    end

    private def collect_type_ref_names(type_ref : TypeRef, names : Array(String))
      if type_ref.union?
        type_ref.union_types.each { |member| collect_type_ref_names(member, names) }
        return
      end
      if name = type_ref.name
        names << name
      end
      type_ref.args.each { |arg| collect_type_ref_names(arg, names) }
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
        seen = Set(String).new
        types = types.select { |t| seen.add?(t.display) }
        return types.size == 1 ? types.first : TypeRef.union(types)
      end

      name = type_ref.name
      return receiver_type if name == "self"
      return substitutions[name] if name && substitutions[name]?
      return type_ref if type_ref.args.empty? || name.nil?

      args = type_ref.args.map { |arg| substitute_type_ref(arg, substitutions, receiver_type) }
      TypeRef.named(name, args)
    end

    private def qualify_type_ref(type_ref : TypeRef, context : String?) : TypeRef
      return type_ref unless context
      if type_ref.union?
        types = type_ref.union_types.map { |m| qualify_type_ref(m, context) }
        return TypeRef.union(types)
      end
      name = type_ref.name
      return type_ref unless name
      args = type_ref.args.empty? ? type_ref.args : type_ref.args.map { |a| qualify_type_ref(a, context) }
      return TypeRef.named(name, args) if name.includes?("::")
      return TypeRef.named(name, args) if find_type(name)
      parts = context.split("::")
      while parts.size > 0
        qualified = (parts + [name]).join("::")
        if find_type(qualified)
          return TypeRef.named(qualified, args)
        end
        parts.pop
      end
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

    private def infer_pointer_deref_type(receiver_type : TypeRef, method_name : String) : TypeRef?
      return nil unless {"current", "value", "[]"}.includes?(method_name)
      name = receiver_type.name
      return nil unless name
      base_name = name.starts_with?("::") ? name[2..] : name
      return nil unless base_name == "Pointer"
      receiver_type.args.first?
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

    private def find_local_assignment_value(scope_def : Crystal::Def, name : String, cursor : Crystal::Location?) : Crystal::ASTNode?
      collector = AssignmentValueCollector.new(name, cursor)
      scope_def.body.accept(collector)
      collector.value
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
