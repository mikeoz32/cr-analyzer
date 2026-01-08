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

    def visit(node : Crystal::Def) : Bool
      false
    end

    def visit(node : Crystal::Macro) : Bool
      false
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
          location: @index.location_for(member)
        )
        @index.attach member_element, enum_element
      end

      @owner_stack << enum_element
      node.accept_children(self)
      @owner_stack.pop
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
        location: @index.location_for(node),
        doc: node.doc
      )
      @index.attach method_element, owner
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
