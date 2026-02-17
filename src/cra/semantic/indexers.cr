require "compiler/crystal/syntax"
require "./semantic_index"
require "./type_ref_helper"
require "./extensions"

module CRA::Psi
  # First pass: build type shells so later passes can attach definitions.
  class SkeletonIndexer < Crystal::Visitor
    def initialize(@index : SemanticIndex)
      @owner_stack = [] of PsiElement
    end

    def index(program : Crystal::ASTNode)
      program.accept(self)
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::Expressions) : Bool
      node.accept_children(self)
      false
    end

    def visit(node : Crystal::ModuleDef) : Bool
      name = qualified_name(node.name)
      parent = @owner_stack.last?.as?(CRA::Psi::Module)
      if !parent
        if parent_name = parent_name_of(name)
          parent = @index.find_module(parent_name, true)
        end
      end
      module_element = @index.ensure_module(
        name,
        parent,
        @index.location_for(node),
        node.type_vars || [] of String,
        node.doc
      )
      @owner_stack << module_element
      node.accept_children(self)
      @owner_stack.pop
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      name = qualified_name(node.name)
      parent = @owner_stack.last?.as?(CRA::Psi::Module | CRA::Psi::Class)
      if !parent
        if parent_name = parent_name_of(name)
          if found_class = @index.find_class(parent_name)
            parent = found_class
          elsif found_module = @index.find_module(parent_name, true)
            parent = found_module
          end
        end
      end
      class_element = @index.ensure_class(
        name,
        parent,
        @index.location_for(node),
        node.type_vars || [] of String,
        node.doc
      )
      if superclass = node.superclass
        @index.set_superclass(class_element.name, superclass)
      end
      @owner_stack << class_element
      node.accept_children(self)
      @owner_stack.pop
      false
    end

    def visit(node : Crystal::EnumDef) : Bool
      name = qualified_name(node.name)
      parent = @owner_stack.last?
      if !parent
        if parent_name = parent_name_of(name)
          parent = @index.find_module(parent_name, true) || @index.find_class(parent_name) || @index.find_enum(parent_name)
        end
      end
      enum_element = @index.ensure_enum(name, parent, @index.location_for(node), node.doc)
      @owner_stack << enum_element
      node.accept_children(self)
      @owner_stack.pop
      false
    end

    def visit(node : Crystal::LibDef) : Bool
      name = node.name.full
      owner = @owner_stack.last?.as?(CRA::Psi::Module)
      if !owner && name.includes?("::")
        if parent_name = parent_name_of(name)
          owner = @index.find_module(parent_name, true)
        end
      elsif owner
        name = "#{owner.name}::#{name}"
      end
      module_element = @index.ensure_module(
        name,
        owner,
        @index.location_for(node),
        [] of String,
        node.doc
      )
      @owner_stack << module_element
      node.accept_children(self)
      @owner_stack.pop
      false
    end

    def visit(node : Crystal::CStructOrUnionDef) : Bool
      owner = @owner_stack.last?
      name = owner ? "#{owner.name}::#{node.name}" : node.name
      parent = owner.as?(CRA::Psi::Module | CRA::Psi::Class)
      class_element = @index.ensure_class(
        name,
        parent,
        @index.location_for(node),
        [] of String,
        node.doc
      )
      @owner_stack << class_element
      node.accept_children(self)
      @owner_stack.pop
      false
    end

    def visit(node : Crystal::Def) : Bool
      false
    end

    def visit(node : Crystal::Macro) : Bool
      false
    end

    def visit(node : Crystal::MacroIf) : Bool
      expand_macro_if_text(node)
      false
    end

    private def expand_macro_if_text(node : Crystal::MacroIf)
      expand_macro_branch(node.then)
      expand_macro_branch(node.else)
    end

    private def expand_macro_branch(node : Crystal::ASTNode)
      text = String.build { |io| collect_macro_literals(node, io) }
      return if text.blank?
      begin
        parser = Crystal::Parser.new(text)
        parsed = parser.parse
        parsed.accept(self)
      rescue
      end
    end

    private def collect_macro_literals(node : Crystal::ASTNode, io : IO)
      case node
      when Crystal::Expressions
        node.expressions.each { |e| collect_macro_literals(e, io) }
      when Crystal::MacroLiteral
        io << node.value
      when Crystal::MacroIf
        collect_macro_literals(node.then, io)
        collect_macro_literals(node.else, io)
      end
    end

    private def qualified_name(path : Crystal::Path) : String
      name = path.full
      return name if name.includes?("::")
      owner = @owner_stack.last?
      return name unless owner
      "#{owner.name}::#{name}"
    end

    private def parent_name_of(name : String) : String?
      parts = name.split("::")
      return nil if parts.size < 2
      parts[0...-1].join("::")
    end
  end

  # Full indexing pass for methods, includes, and enum members.
  class SemanticIndexer < Crystal::Visitor
    include TypeRefHelper

    def initialize(@index : SemanticIndex, @expand_macros : Bool)
      @owner_stack = [] of PsiElement
    end

    def owner_stack_empty? : Bool
      @owner_stack.empty?
    end

    def index(program : Crystal::ASTNode)
      program.accept(self)
    end

    def index_virtual(program : Crystal::ASTNode, file : String, owner : PsiElement?)
      @index.with_current_file(file) do
        if owner
          @owner_stack << owner
        end
        begin
          program.accept(self)
        ensure
          @owner_stack.pop if owner
        end
      end
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::Expressions) : Bool
      node.accept_children(self)
      false
    end

    def visit(node : Crystal::ModuleDef) : Bool
      name = qualified_name(node.name)
      parent = @owner_stack.last?.as?(CRA::Psi::Module)
      if !parent
        if parent_name = parent_name_of(name)
          parent = @index.find_module(parent_name, true)
        end
      end
      module_element = @index.ensure_module(
        name,
        parent,
        @index.location_for(node),
        node.type_vars || [] of String,
        node.doc
      )
      @owner_stack << module_element
      node.accept_children(self)
      @owner_stack.pop
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      name = qualified_name(node.name)
      parent = @owner_stack.last?.as?(CRA::Psi::Module | CRA::Psi::Class)
      if !parent
        if parent_name = parent_name_of(name)
          if found_class = @index.find_class(parent_name)
            parent = found_class
          elsif found_module = @index.find_module(parent_name, true)
            parent = found_module
          end
        end
      end
      class_element = @index.ensure_class(
        name,
        parent,
        @index.location_for(node),
        node.type_vars || [] of String,
        node.doc
      )
      if superclass = node.superclass
        @index.set_superclass(class_element.name, superclass)
      end
      @owner_stack << class_element
      node.accept_children(self)
      @owner_stack.pop
      false
    end

    def visit(node : Crystal::EnumDef) : Bool
      name = qualified_name(node.name)
      parent = @owner_stack.last?
      if !parent
        if parent_name = parent_name_of(name)
          parent = @index.find_module(parent_name, true) || @index.find_class(parent_name) || @index.find_enum(parent_name)
        end
      end
      enum_element = @index.ensure_enum(name, parent, @index.location_for(node), node.doc)

      node.members.each do |member|
        next unless member.is_a?(Crystal::Arg)
        member_element = CRA::Psi::EnumMember.new(
          file: @index.current_file,
          name: member.name,
          owner: enum_element,
          location: @index.location_for(member),
          doc: member.doc
        )
        @index.attach member_element, enum_element
      end

      @owner_stack << enum_element
      node.accept_children(self)
      @owner_stack.pop
      false
    end

    def visit(node : Crystal::LibDef) : Bool
      name = node.name.full
      owner = @owner_stack.last?.as?(CRA::Psi::Module)
      if !owner && name.includes?("::")
        if parent_name = parent_name_of(name)
          owner = @index.find_module(parent_name, true)
        end
      elsif owner
        name = "#{owner.name}::#{name}"
      end
      module_element = @index.ensure_module(
        name,
        owner,
        @index.location_for(node),
        [] of String,
        node.doc
      )
      @owner_stack << module_element
      node.accept_children(self)
      @owner_stack.pop
      false
    end

    def visit(node : Crystal::CStructOrUnionDef) : Bool
      owner = @owner_stack.last?
      name = owner ? "#{owner.name}::#{node.name}" : node.name
      parent = owner.as?(CRA::Psi::Module | CRA::Psi::Class)
      class_element = @index.ensure_class(
        name,
        parent,
        @index.location_for(node),
        [] of String,
        node.doc
      )
      fields = case body = node.body
               when Crystal::Expressions then body.expressions
               when Crystal::TypeDeclaration then [body.as(Crystal::ASTNode)]
               else [] of Crystal::ASTNode
               end
      fields.each do |expr|
        next unless expr.is_a?(Crystal::TypeDeclaration)
        field_var = expr.var
        next unless field_var.is_a?(Crystal::Var)
        field_type_ref = type_ref_from_type(expr.declared_type)
        next unless field_type_ref
        method_element = CRA::Psi::Method.new(
          file: @index.current_file,
          name: field_var.name,
          min_arity: 0,
          max_arity: 0,
          class_method: false,
          owner: class_element,
          return_type: expr.declared_type.to_s,
          return_type_ref: field_type_ref,
          parameters: [] of String,
          location: @index.location_for(expr),
          doc: expr.doc
        )
        @index.attach method_element, class_element
        @index.register_method(method_element)
      end
      false
    end

    def visit(node : Crystal::FunDef) : Bool
      owner = @owner_stack.last?
      return false unless owner
      return false unless owner.is_a?(CRA::Psi::Module) || owner.is_a?(CRA::Psi::Class)

      return_type_ref = node.return_type ? type_ref_from_type(node.return_type.not_nil!) : nil
      param_type_refs = node.args.map { |arg|
        restriction = arg.restriction
        restriction ? type_ref_from_type(restriction) : nil
      }
      method_element = CRA::Psi::Method.new(
        file: @index.current_file,
        name: node.name,
        min_arity: node.args.size,
        max_arity: node.args.size,
        class_method: true,
        owner: owner,
        return_type: node.return_type ? node.return_type.to_s : "Nil",
        return_type_ref: return_type_ref,
        parameters: node.args.map(&.name),
        param_type_refs: param_type_refs,
        location: @index.location_for(node),
        doc: node.doc
      )
      @index.attach method_element, owner
      @index.register_method(method_element)
      false
    end

    def visit(node : Crystal::Alias) : Bool
      name = qualified_name(node.name)
      target = type_ref_from_type(node.value)
      @index.record_alias(name, target, @index.location_for(node), node.doc)
      false
    end

    def visit(node : Crystal::Include) : Bool
      owner = @owner_stack.last?
      return false unless owner
      @index.record_include(owner, node.name)
      false
    end

    def visit(node : Crystal::Def) : Bool
      owner = @owner_stack.last?
      return false unless owner
      return false unless owner.is_a?(CRA::Psi::Module) || owner.is_a?(CRA::Psi::Class) || owner.is_a?(CRA::Psi::Enum)

      arity = method_arity(node)
      class_method = !node.receiver.nil?
      return_type_ref = nil
      if return_type = node.return_type
        return_type_ref = type_ref_from_type(return_type)
      end
      block_arg_types = extract_block_arg_types(node)
      has_untyped_block = block_arg_types.empty? && node.block_arg
      if has_untyped_block && (body = node.body)
        block_arg_types = extract_yield_arg_types(body, node, owner)
      end
      block_return_type_ref = extract_block_return_type(node)
      param_type_refs = node.args.map { |arg|
        restriction = arg.restriction
        restriction ? type_ref_from_type(restriction) : nil
      }
      free_vars = node.free_vars || [] of String
      method_element = CRA::Psi::Method.new(
        file: @index.current_file,
        name: node.name,
        min_arity: arity[:min],
        max_arity: arity[:max],
        class_method: class_method,
        owner: owner,
        return_type: node.return_type ? node.return_type.to_s : "Nil",
        return_type_ref: return_type_ref,
        parameters: node.args.map(&.name),
        param_type_refs: param_type_refs,
        free_vars: free_vars,
        block_arg_types: block_arg_types,
        block_return_type_ref: block_return_type_ref,
        location: @index.location_for(node),
        doc: node.doc
      )
      @index.attach method_element, owner
      @index.register_method(method_element)
      if has_untyped_block && block_arg_types.empty?
        @index.add_pending_yield_def(node, owner, method_element)
      end
      if body = node.body
        context_name = owner.responds_to?(:name) ? owner.name : nil
        body.accept(CallCollector.new(@index, method_element, node, context_name))
      end
      false
    end

    def visit(node : Crystal::Macro) : Bool
      @index.register_macro_in_scope(node, current_scope)
      false
    end

    def visit(node : Crystal::Call) : Bool
      if @expand_macros
        @index.expand_macro_call_in_scope(node, current_scope, self)
      end
      true
    end

    def visit(node : Crystal::MacroIf) : Bool
      expand_macro_if_text(node)
      false
    end

    private def expand_macro_if_text(node : Crystal::MacroIf)
      expand_macro_branch(node.then)
      expand_macro_branch(node.else)
    end

    private def expand_macro_branch(node : Crystal::ASTNode)
      text = String.build { |io| collect_macro_literals(node, io) }
      return if text.blank?
      begin
        parser = Crystal::Parser.new(text)
        parsed = parser.parse
        parsed.accept(self)
      rescue
      end
    end

    private def collect_macro_literals(node : Crystal::ASTNode, io : IO)
      case node
      when Crystal::Expressions
        node.expressions.each { |e| collect_macro_literals(e, io) }
      when Crystal::MacroLiteral
        io << node.value
      when Crystal::MacroIf
        collect_macro_literals(node.then, io)
        collect_macro_literals(node.else, io)
      end
    end

    private def current_scope : String
      @owner_stack.last?.try(&.name) || ""
    end

    private def qualified_name(path : Crystal::Path) : String
      name = path.full
      return name if name.includes?("::")
      owner = @owner_stack.last?
      return name unless owner
      "#{owner.name}::#{name}"
    end

    private def parent_name_of(name : String) : String?
      parts = name.split("::")
      return nil if parts.size < 2
      parts[0...-1].join("::")
    end

    private def method_arity(node : Crystal::Def) : {min: Int32, max: Int32?}
      splat_index = node.splat_index
      required = 0
      node.args.each_with_index do |arg, idx|
        next if splat_index && idx == splat_index
        required += 1 unless arg.default_value
      end
      max = splat_index ? nil : node.args.size
      {min: required, max: max}
    end

    private def extract_block_arg_types(node : Crystal::Def) : Array(CRA::Psi::TypeRef)
      block_arg = node.block_arg
      return [] of CRA::Psi::TypeRef unless block_arg
      restriction = block_arg.restriction
      return [] of CRA::Psi::TypeRef unless restriction.is_a?(Crystal::ProcNotation)
      inputs = restriction.inputs
      return [] of CRA::Psi::TypeRef unless inputs
      types = [] of CRA::Psi::TypeRef
      inputs.each do |input|
        if type_ref = type_ref_from_type(input)
          types << type_ref
        end
      end
      types
    end

    private def extract_block_return_type(node : Crystal::Def) : CRA::Psi::TypeRef?
      block_arg = node.block_arg
      return nil unless block_arg
      restriction = block_arg.restriction
      return nil unless restriction.is_a?(Crystal::ProcNotation)
      output = restriction.output
      return nil unless output
      type_ref_from_type(output)
    end

    private def extract_yield_arg_types(body : Crystal::ASTNode, def_node : Crystal::Def, owner : PsiElement) : Array(CRA::Psi::TypeRef)
      extractor = YieldTypeExtractor.new(def_node, owner, @index)
      body.accept(extractor)
      extractor.types
    end

    # Extracts types from the first yield statement in a method body.
    # Handles simple patterns: yield with vars assigned from .new, typed args,
    # or self references.  Also tracks block params from calls whose methods
    # have already been indexed.
    class YieldTypeExtractor < Crystal::Visitor
      include TypeRefHelper

      getter types : Array(CRA::Psi::TypeRef)

      def initialize(@def_node : Crystal::Def, @owner : PsiElement, @index : SemanticIndex)
        @types = [] of CRA::Psi::TypeRef
        @locals = {} of String => CRA::Psi::TypeRef
        @found = false
      end

      def visit(node : Crystal::ASTNode) : Bool
        !@found
      end

      def visit(node : Crystal::Call) : Bool
        return false if @found
        if block = node.block
          hints = resolve_block_hints(node)
          block.args.each_with_index do |arg, idx|
            if hint = hints[idx]?
              @locals[arg.name] = hint
            end
          end
        end
        true
      end

      def visit(node : Crystal::Assign) : Bool
        return false if @found
        if (target = node.target).is_a?(Crystal::Var)
          ref = type_ref_from_value(node.value)
          if ref.nil? && (call = node.value).is_a?(Crystal::Call)
            if (call.name == "new" || call.name == "null" || call.name == "malloc") && call.obj.nil?
              ref = CRA::Psi::TypeRef.named(@owner.name)
            end
          end
          @locals[target.name] = ref if ref
        end
        true
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::Yield) : Bool
        return false if @found
        @found = true
        resolved = [] of CRA::Psi::TypeRef
        node.exps.each do |exp|
          type_ref = infer_yield_exp(exp)
          if type_ref
            resolved << type_ref
          else
            return false
          end
        end
        @types = resolved
        false
      end

      private def resolve_block_hints(call : Crystal::Call) : Array(CRA::Psi::TypeRef)
        obj = call.obj
        return [] of CRA::Psi::TypeRef unless obj
        receiver_ref = case obj
                       when Crystal::Path
                         CRA::Psi::TypeRef.named(obj.full)
                       when Crystal::Generic
                         type_ref_from_type(obj)
                       else
                         nil
                       end
        return [] of CRA::Psi::TypeRef unless receiver_ref
        owner = @index.resolve_type_ref_public(receiver_ref)
        return [] of CRA::Psi::TypeRef unless owner
        class_method = obj.is_a?(Crystal::Path) || obj.is_a?(Crystal::Generic)
        candidates = @index.find_methods_in_type(owner, call.name, class_method)
        return [] of CRA::Psi::TypeRef if candidates.empty?
        method = candidates.first
        types = method.block_arg_types
        owner_name = method.owner.try(&.name) || owner.name
        types.map { |t| t.name == "self" ? CRA::Psi::TypeRef.named(owner_name) : t }
      end

      private def infer_yield_exp(node : Crystal::ASTNode) : CRA::Psi::TypeRef?
        if ref = type_ref_from_value(node)
          return ref
        end
        case node
        when Crystal::Var
          if node.name == "self"
            return CRA::Psi::TypeRef.named(@owner.name)
          end
          @def_node.args.each do |arg|
            if arg.name == node.name && (restriction = arg.restriction)
              return type_ref_from_type(restriction)
            end
          end
          @locals[node.name]?
        when Crystal::InstanceVar
          nil
        when Crystal::Call
          if node.name == "new" || node.name == "null" || node.name == "malloc"
            if obj = node.obj
              return type_ref_from_type(obj)
            end
          end
          nil
        else
          nil
        end
      end
    end

    # Collects call edges from a method body to resolved method definitions.
    class CallCollector < Crystal::Visitor
      def initialize(@index : SemanticIndex, @from_method : CRA::Psi::Method, @scope_def : Crystal::Def, @context_name : String?)
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::Call) : Bool
        call_loc = @index.location_for(node)

        if (node.obj.nil? && node.name == "super") || (node.obj.nil? && node.name == "previous_def")
          @index.super_methods_for(@from_method).each do |target|
            @index.record_call(@from_method, target, call_loc)
          end
          node.accept_children(self)
          return false
        end

        targets = @index.find_definitions(
          node,
          @context_name,
          @scope_def,
          nil,
          node.location,
          @index.current_file
        )
        targets.each do |target|
          if method = target.as?(CRA::Psi::Method)
            @index.record_call(@from_method, method, call_loc)
          end
        end
        node.accept_children(self)
        false
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::ClassDef) : Bool
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        false
      end

      def visit(node : Crystal::Macro) : Bool
        false
      end
    end
  end

  # Collects macro definitions with scope awareness.
  class MacroRegistry < Crystal::Visitor
    def initialize(@index : SemanticIndex)
      @scope_stack = [] of String
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::Macro) : Bool
      @index.register_macro_in_scope(node, current_scope)
      false
    end

    def visit(node : Crystal::ModuleDef) : Bool
      push_scope(node.name)
      node.accept_children(self)
      @scope_stack.pop
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      push_scope(node.name)
      node.accept_children(self)
      @scope_stack.pop
      false
    end

    def visit(node : Crystal::EnumDef) : Bool
      push_scope(node.name)
      node.accept_children(self)
      @scope_stack.pop
      false
    end

    private def current_scope : String
      @scope_stack.last? || ""
    end

    private def push_scope(path : Crystal::Path)
      name = path.full
      if name.includes?("::") || current_scope.empty?
        @scope_stack << name
      else
        @scope_stack << "#{current_scope}::#{name}"
      end
    end
  end

  # Expands macros before indexing the original AST.
  class MacroPreExpander < Crystal::Visitor
    def initialize(@index : SemanticIndex, @indexer : SemanticIndexer)
      @scope_stack = [] of String
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::Macro) : Bool
      false
    end

    def visit(node : Crystal::Call) : Bool
      @index.expand_macro_call_in_scope(node, current_scope, @indexer)
      true
    end

    def visit(node : Crystal::ModuleDef) : Bool
      push_scope(node.name)
      node.accept_children(self)
      @scope_stack.pop
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      push_scope(node.name)
      node.accept_children(self)
      @scope_stack.pop
      false
    end

    def visit(node : Crystal::EnumDef) : Bool
      push_scope(node.name)
      node.accept_children(self)
      @scope_stack.pop
      false
    end

    private def current_scope : String
      @scope_stack.last? || ""
    end

    private def push_scope(path : Crystal::Path)
      name = path.full
      if name.includes?("::") || current_scope.empty?
        @scope_stack << name
      else
        @scope_stack << "#{current_scope}::#{name}"
      end
    end
  end
end
