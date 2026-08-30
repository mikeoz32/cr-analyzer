module CRA::Psi
  class SemanticIndex
    include FacetTypeRefHelper

    private def facet_call_for_context(context : CRA::CompletionContext) : Facet::Compiler::SyntaxNode?
      path = context.facet_node_path
      path.reverse_each.find { |node| node.receiver && node.call_name } ||
        path.reverse_each.find { |node| node.call_name }
    end

    private def facet_member_owner_info(context : CRA::CompletionContext) : {PsiElement, Bool}?
      access = context.facet_node_path.reverse_each.find(&.receiver)
      return nil unless access
      receiver = access.receiver
      return nil unless receiver
      env = build_facet_type_env(context)
      resolve_facet_receiver_owner(receiver, context.enclosing_type_name, context, env)
    end

    private def complete_facet_named_arguments(
      context : CRA::CompletionContext,
      call : Facet::Compiler::SyntaxNode,
    ) : Array(CRA::Types::CompletionItem)
      return [] of CRA::Types::CompletionItem if context.word_prefix.empty?
      methods = facet_signature_help_methods(call, context)
      return [] of CRA::Types::CompletionItem if methods.empty?

      used = call.named_arguments.compact_map(&.name).to_set
      prefix = context.word_prefix
      replace_range = replacement_range(context, prefix)
      items = [] of CRA::Types::CompletionItem
      seen = Set(String).new
      methods.each do |method|
        method.parameters.each do |parameter|
          next if parameter.starts_with?("_") || used.includes?(parameter)
          next unless parameter.starts_with?(prefix)
          next if seen.includes?(parameter)
          seen << parameter
          label = "#{parameter}:"
          items << CRA::Types::CompletionItem.new(
            label: label,
            kind: CRA::Types::CompletionItemKind::Field,
            detail: method_detail(method),
            text_edit: CRA::Types::TextEdit.new(replace_range, "#{label} ")
          )
        end
      end
      items
    end

    private def facet_signature_help_methods(
      call : Facet::Compiler::SyntaxNode,
      context : CRA::CompletionContext,
    ) : Array(Method)
      name = call.call_name
      return [] of Method unless name
      env = build_facet_type_env(context)
      receiver = call.receiver

      if receiver && name == "new" && facet_type_expression?(receiver, env)
        if type_ref = type_ref_from_facet(receiver)
          if owner = resolve_type_ref(type_ref, context.enclosing_type_name)
            class_methods = find_methods_with_ancestors(owner, "new", true)
            return class_methods unless class_methods.empty?
            return find_methods_with_ancestors(owner, "initialize", false)
          end
        end
      end

      owner_info = if receiver
                     resolve_facet_receiver_owner(receiver, context.enclosing_type_name, context, env)
                   elsif type_name = context.enclosing_type_name
                     owner = find_type(type_name)
                     owner ? {owner, facet_class_method?(facet_enclosing_def(context))} : nil
                   end
      return [] of Method unless owner_info
      owner, class_method = owner_info
      find_methods_with_ancestors(owner, name, class_method)
    end

    private def build_facet_type_env(context : CRA::CompletionContext) : TypeEnv
      env = TypeEnv.new
      cursor = context.facet_cursor_offset || Int32::MAX
      type_node = facet_enclosing_type(context)
      def_node = facet_enclosing_def(context)

      if type_node
        if body = type_node.body
          collect_facet_types(body, env, cursor, false, false, context.enclosing_type_name)
          methods = facet_direct_methods(body)
          methods.select { |method| method.name == "initialize" }.each do |method|
            register_facet_parameters(method.parameters, env, false, true)
            method.body.try do |method_body|
              collect_facet_types(method_body, env, cursor, false, false, context.enclosing_type_name)
            end
          end
          methods.each do |method|
            method.body.try do |method_body|
              collect_facet_types(method_body, env, cursor, false, true, context.enclosing_type_name)
            end
          end
        end
      end

      if def_node
        register_facet_parameters(def_node.parameters, env, true, true)
        def_node.body.try do |body|
          collect_facet_types(body, env, cursor, true, false, context.enclosing_type_name)
        end
      end
      env
    end

    private def collect_facet_types(
      node : Facet::Compiler::SyntaxNode,
      env : TypeEnv,
      cursor : Int32,
      collect_locals : Bool,
      fill_only : Bool,
      context : String?,
    ) : Nil
      return if node.span.start > cursor
      return if {
                  Facet::Compiler::NodeKind::Def,
                  Facet::Compiler::NodeKind::MacroDef,
                  Facet::Compiler::NodeKind::Class,
                  Facet::Compiler::NodeKind::Module,
                  Facet::Compiler::NodeKind::Struct,
                  Facet::Compiler::NodeKind::Enum,
                  Facet::Compiler::NodeKind::Lib,
                }.includes?(node.kind)

      if node.kind == Facet::Compiler::NodeKind::Block
        register_facet_parameters(node.parameters, env, collect_locals, false)
      elsif {Facet::Compiler::NodeKind::VarDecl, Facet::Compiler::NodeKind::Assign}.includes?(node.kind)
        target = node.target
        if target
          type_ref = node.declared_type.try { |type| type_ref_from_facet(type) }
          type_ref ||= node.value.try { |value| infer_facet_type_ref(value, context, env) }
          assign_facet_type(target, type_ref, env, collect_locals, fill_only) if type_ref
        end
      end

      node.children.each do |child|
        collect_facet_types(child, env, cursor, collect_locals, fill_only, context)
      end
    end

    private def facet_local_names(context : CRA::CompletionContext) : Set(String)
      names = Set(String).new
      definition = facet_enclosing_def(context)
      return names unless definition
      definition.parameters.each do |parameter|
        parameter.name.try { |name| names << name.lstrip('@') }
      end
      cursor = context.facet_cursor_offset || Int32::MAX
      definition.body.try { |body| collect_facet_local_names(body, cursor, names) }
      names
    end

    private def collect_facet_local_names(
      node : Facet::Compiler::SyntaxNode,
      cursor : Int32,
      names : Set(String),
    ) : Nil
      return if node.span.start > cursor
      return if {
                  Facet::Compiler::NodeKind::Def,
                  Facet::Compiler::NodeKind::MacroDef,
                  Facet::Compiler::NodeKind::Class,
                  Facet::Compiler::NodeKind::Module,
                  Facet::Compiler::NodeKind::Struct,
                  Facet::Compiler::NodeKind::Enum,
                  Facet::Compiler::NodeKind::Lib,
                }.includes?(node.kind)
      if node.kind == Facet::Compiler::NodeKind::Block
        node.parameters.each { |parameter| parameter.name.try { |name| names << name.lstrip('@') } }
      elsif target = node.target
        if target.kind == Facet::Compiler::NodeKind::Ident
          target.symbol_name.try { |name| names << name }
        end
      end
      node.children.each { |child| collect_facet_local_names(child, cursor, names) }
    end

    private def complete_facet_scoped_variables(
      context : CRA::CompletionContext,
      prefix : String,
      class_variable : Bool,
    ) : Array(CRA::Types::CompletionItem)?
      type = facet_enclosing_type(context)
      return nil unless type && {Facet::Compiler::NodeKind::Class, Facet::Compiler::NodeKind::Struct}.includes?(type.kind)
      names = Set(String).new
      type.body.try { |body| collect_facet_scoped_variable_names(body, class_variable, names) }
      replace_range = replacement_range(context, prefix)
      kind = class_variable ? CRA::Types::CompletionItemKind::Variable : CRA::Types::CompletionItemKind::Property
      names.compact_map do |name|
        next unless name.starts_with?(prefix)
        CRA::Types::CompletionItem.new(
          label: name,
          kind: kind,
          text_edit: CRA::Types::TextEdit.new(replace_range, name)
        )
      end
    end

    private def collect_facet_scoped_variable_names(
      node : Facet::Compiler::SyntaxNode,
      class_variable : Bool,
      names : Set(String),
    ) : Nil
      return if {
                  Facet::Compiler::NodeKind::Class,
                  Facet::Compiler::NodeKind::Module,
                  Facet::Compiler::NodeKind::Struct,
                  Facet::Compiler::NodeKind::Enum,
                  Facet::Compiler::NodeKind::Lib,
                  Facet::Compiler::NodeKind::MacroDef,
                }.includes?(node.kind)
      if {Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Block}.includes?(node.kind)
        node.parameters.each do |parameter|
          parameter.name.try do |name|
            names << name if class_variable ? name.starts_with?("@@") : name.starts_with?("@") && !name.starts_with?("@@")
          end
        end
      end
      if target = node.target
        expected = class_variable ? Facet::Compiler::NodeKind::ClassVar : Facet::Compiler::NodeKind::InstanceVar
        if target.kind == expected
          target.symbol_name.try { |name| names << name }
        end
      end
      node.children.each { |child| collect_facet_scoped_variable_names(child, class_variable, names) }
    end

    private def register_facet_parameters(
      parameters : Array(Facet::Compiler::SyntaxNode),
      env : TypeEnv,
      collect_locals : Bool,
      shorthand_fields : Bool,
    ) : Nil
      parameters.each do |parameter|
        name = parameter.name
        next unless name
        type_ref = parameter.declared_type.try { |type| type_ref_from_facet(type) }
        next unless type_ref
        semantic_name = name.lstrip('@')
        env.locals[semantic_name] = type_ref if collect_locals
        next unless shorthand_fields
        if name.starts_with?("@@")
          env.cvars[name] = type_ref
        elsif name.starts_with?("@")
          env.ivars[name] = type_ref
        end
      end
    end

    private def assign_facet_type(
      target : Facet::Compiler::SyntaxNode,
      type_ref : TypeRef,
      env : TypeEnv,
      collect_locals : Bool,
      fill_only : Bool,
    ) : Nil
      name = target.symbol_name
      return unless name
      store = case target.kind
              when Facet::Compiler::NodeKind::Ident
                collect_locals ? env.locals : nil
              when Facet::Compiler::NodeKind::InstanceVar
                env.ivars
              when Facet::Compiler::NodeKind::ClassVar
                env.cvars
              end
      return unless store
      return if fill_only && store.has_key?(name)
      store[name] = type_ref
    end

    private def infer_facet_type_ref(
      node : Facet::Compiler::SyntaxNode,
      context : String?,
      env : TypeEnv,
      depth : Int32 = 0,
    ) : TypeRef?
      return nil if depth > 5
      case node.kind
      when Facet::Compiler::NodeKind::Ident
        name = node.symbol_name
        return nil unless name
        return TypeRef.named("self") if name == "self"
        env.locals[name]? || (name[0]?.try(&.ascii_uppercase?) ? TypeRef.named(name) : nil)
      when Facet::Compiler::NodeKind::InstanceVar
        node.symbol_name.try { |name| env.ivars[name]? }
      when Facet::Compiler::NodeKind::ClassVar
        node.symbol_name.try { |name| env.cvars[name]? }
      when Facet::Compiler::NodeKind::Const, Facet::Compiler::NodeKind::Path,
           Facet::Compiler::NodeKind::TypeApply
        type_ref_from_facet(node)
      when Facet::Compiler::NodeKind::LiteralString, Facet::Compiler::NodeKind::StringInterpolation
        TypeRef.named("String")
      when Facet::Compiler::NodeKind::LiteralChar
        TypeRef.named("Char")
      when Facet::Compiler::NodeKind::LiteralBool
        TypeRef.named("Bool")
      when Facet::Compiler::NodeKind::LiteralNil
        TypeRef.named("Nil")
      when Facet::Compiler::NodeKind::LiteralNumber
        TypeRef.named(facet_number_type(node.text))
      when Facet::Compiler::NodeKind::Array
        element = node.children.first?.try { |child| infer_facet_type_ref(child, context, env, depth + 1) }
        TypeRef.named("Array", element ? [element] : [] of TypeRef)
      when Facet::Compiler::NodeKind::Tuple
        values = node.children.compact_map { |child| infer_facet_type_ref(child, context, env, depth + 1) }
        TypeRef.named("Tuple", values)
      when Facet::Compiler::NodeKind::Assign, Facet::Compiler::NodeKind::VarDecl
        node.value.try { |value| infer_facet_type_ref(value, context, env, depth + 1) }
      when Facet::Compiler::NodeKind::Call, Facet::Compiler::NodeKind::CallWithBlock,
           Facet::Compiler::NodeKind::Binary
        infer_facet_call_type(node, context, env, depth + 1)
      when Facet::Compiler::NodeKind::Index
        receiver = node.child(0)
        receiver.try do |value|
          receiver_type = infer_facet_type_ref(value, context, env, depth + 1)
          facet_index_return_type(receiver_type)
        end
      else
        nil
      end
    end

    private def infer_facet_call_type(
      call : Facet::Compiler::SyntaxNode,
      context : String?,
      env : TypeEnv,
      depth : Int32,
    ) : TypeRef?
      name = call.call_name
      return nil unless name
      receiver = call.receiver
      if name == "new" && receiver
        return type_ref_from_facet(receiver)
      end

      receiver_type = receiver.try { |value| infer_facet_type_ref(value, context, env, depth + 1) }
      receiver_type ||= TypeRef.named(context) if context
      return nil unless receiver_type
      return facet_index_return_type(receiver_type) if name == "[]"
      owner = resolve_type_ref(receiver_type, context)
      return nil unless owner
      class_method = receiver ? facet_type_expression?(receiver, env) : false
      candidates = find_methods_with_ancestors(owner, name, class_method)
      narrowed = filter_facet_methods_by_arity(candidates, call.arguments.size)
      candidates = narrowed unless narrowed.empty?
      method = candidates.find(&.return_type_ref) || candidates.first?
      method.try { |candidate| infer_method_return_type(candidate, receiver_type) }
    end

    private def resolve_facet_receiver_owner(
      receiver : Facet::Compiler::SyntaxNode,
      context : String?,
      completion : CRA::CompletionContext,
      env : TypeEnv,
    ) : {PsiElement, Bool}?
      if receiver.kind == Facet::Compiler::NodeKind::Ident && receiver.symbol_name == "self"
        if context && (owner = find_type(context))
          return {owner, facet_class_method?(facet_enclosing_def(completion))}
        end
      end

      if type_ref = infer_facet_type_ref(receiver, context, env)
        if owner = resolve_type_ref(type_ref, context)
          class_method = facet_type_expression?(receiver, env) || receiver.kind == Facet::Compiler::NodeKind::ClassVar
          return {owner, class_method}
        end
      end

      if context && receiver.kind == Facet::Compiler::NodeKind::InstanceVar
        if owner = find_class(context)
          return {owner, false}
        end
      end
      nil
    end

    private def facet_type_expression?(node : Facet::Compiler::SyntaxNode, env : TypeEnv) : Bool
      case node.kind
      when Facet::Compiler::NodeKind::Const, Facet::Compiler::NodeKind::Path,
           Facet::Compiler::NodeKind::TypeApply
        true
      when Facet::Compiler::NodeKind::Ident
        name = node.symbol_name
        !!(name && !env.locals.has_key?(name) && name[0]?.try(&.ascii_uppercase?))
      else
        false
      end
    end

    private def facet_enclosing_def(context : CRA::CompletionContext) : Facet::Compiler::SyntaxNode?
      context.facet_node_path.reverse_each.find { |node| node.kind == Facet::Compiler::NodeKind::Def }
    end

    private def facet_enclosing_type(context : CRA::CompletionContext) : Facet::Compiler::SyntaxNode?
      context.facet_node_path.reverse_each.find do |node|
        {
          Facet::Compiler::NodeKind::Class,
          Facet::Compiler::NodeKind::Module,
          Facet::Compiler::NodeKind::Struct,
          Facet::Compiler::NodeKind::Enum,
        }.includes?(node.kind)
      end
    end

    private def facet_class_method?(node : Facet::Compiler::SyntaxNode?) : Bool
      return false unless node
      name = node.name_node
      !!(name && {Facet::Compiler::NodeKind::Binary, Facet::Compiler::NodeKind::Path}.includes?(name.kind))
    end

    private def facet_direct_methods(body : Facet::Compiler::SyntaxNode) : Array(Facet::Compiler::SyntaxNode)
      methods = [] of Facet::Compiler::SyntaxNode
      body.children.each do |child|
        if child.kind == Facet::Compiler::NodeKind::Def
          methods << child
        elsif child.kind == Facet::Compiler::NodeKind::Expressions
          methods.concat(facet_direct_methods(child))
        end
      end
      methods
    end

    private def filter_facet_methods_by_arity(methods : Array(Method), arity : Int32) : Array(Method)
      methods.select do |method|
        arity >= method.min_arity && (method.max_arity.nil? || arity <= method.max_arity.not_nil!)
      end
    end

    private def facet_index_return_type(receiver : TypeRef?) : TypeRef?
      return nil unless receiver
      name = receiver.name.to_s.lchop("::")
      case name
      when "Array", "Slice", "StaticArray", "Deque"
        receiver.args.first?
      when "Hash"
        receiver.args[1]?
      else
        nil
      end
    end

    private def facet_number_type(text : String) : String
      suffix = text.downcase
      return "Float32" if suffix.ends_with?("f32")
      return "Float64" if suffix.includes?('.') || suffix.ends_with?("f64")
      return "Int64" if suffix.ends_with?("i64")
      return "UInt64" if suffix.ends_with?("u64")
      return "UInt32" if suffix.ends_with?("u32")
      "Int32"
    end
  end
end
