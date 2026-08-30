require "facet/compiler"
require "./semantic_index"

module CRA::Psi
  # Declaration-level SemanticIndex producer for Facet's native AST. This is a
  # parallel index during cutover; it intentionally stores semantic names,
  # TypeRefs, and Locations rather than syntax nodes.
  class FacetSemanticIndexer
    def initialize(@index : SemanticIndex)
      @owners = [] of PsiElement
    end

    def index(tree : Facet::Compiler::SyntaxTree) : Nil
      @tree = tree
      build_skeleton(tree.root)
      @owners.clear
      build_semantics(tree.root)
    end

    private def build_skeleton(node : Facet::Compiler::SyntaxNode) : Nil
      case node.kind
      when Facet::Compiler::NodeKind::Module, Facet::Compiler::NodeKind::Lib
        name = qualified_name(node.name.to_s)
        owner = module_owner(name)
        element = @index.ensure_module(name, owner, location_for(node), type_vars(node), node.doc)
        with_owner(element) { node.body.try { |body| build_skeleton(body) } }
      when Facet::Compiler::NodeKind::Class, Facet::Compiler::NodeKind::Struct
        name = qualified_name(node.name.to_s)
        owner = type_owner(name)
        element = @index.ensure_class(name, owner, location_for(node), type_vars(node), node.doc)
        with_owner(element) { node.body.try { |body| build_skeleton(body) } }
      when Facet::Compiler::NodeKind::Enum
        name = qualified_name(node.name.to_s)
        owner = type_owner(name)
        element = @index.ensure_enum(name, owner, location_for(node), node.doc)
        with_owner(element) { node.body.try { |body| build_skeleton(body) } }
      when Facet::Compiler::NodeKind::MacroDef
        # Macro templates are indexed by Facet's ProgramIndex, not as runtime
        # declarations in the editor semantic model.
      else
        node.children.each { |child| build_skeleton(child) }
      end
    end

    private def build_semantics(node : Facet::Compiler::SyntaxNode) : Nil
      case node.kind
      when Facet::Compiler::NodeKind::Module, Facet::Compiler::NodeKind::Lib
        name = qualified_name(node.name.to_s)
        owner = module_owner(name)
        element = @index.ensure_module(name, owner, location_for(node), type_vars(node), node.doc)
        with_owner(element) { node.body.try { |body| build_semantics(body) } }
      when Facet::Compiler::NodeKind::Class, Facet::Compiler::NodeKind::Struct
        name = qualified_name(node.name.to_s)
        owner = type_owner(name)
        element = @index.ensure_class(name, owner, location_for(node), type_vars(node), node.doc)
        node.superclass.try(&.symbol_name).try { |superclass| @index.set_superclass(element.name, superclass) }
        with_owner(element) { node.body.try { |body| build_semantics(body) } }
      when Facet::Compiler::NodeKind::Enum
        name = qualified_name(node.name.to_s)
        owner = type_owner(name)
        element = @index.ensure_enum(name, owner, location_for(node), node.doc)
        add_enum_members(node, element)
        with_owner(element) { node.body.try { |body| build_semantics(body) } }
      when Facet::Compiler::NodeKind::Alias, Facet::Compiler::NodeKind::TypeDef
        name = qualified_name(node.name.to_s)
        target = node.child(1).try { |value| type_ref(value) }
        @index.record_alias(name, target, location_for(node), node.doc)
      when Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Fun
        add_method(node)
      when Facet::Compiler::NodeKind::Call
        add_include(node)
        node.children.each { |child| build_semantics(child) }
      when Facet::Compiler::NodeKind::MacroDef
      else
        node.children.each { |child| build_semantics(child) }
      end
    end

    private def add_method(node : Facet::Compiler::SyntaxNode) : Nil
      owner = @owners.last?
      return unless owner.is_a?(CRA::Psi::Module) || owner.is_a?(CRA::Psi::Class) || owner.is_a?(CRA::Psi::Enum)

      parameters = node.parameters.reject { |param| param.kind == Facet::Compiler::NodeKind::BlockParam }
      required = parameters.count do |param|
        next false if {Facet::Compiler::NodeKind::Splat, Facet::Compiler::NodeKind::DoubleSplat}.includes?(param.kind)
        children = param.children
        children.empty? || children.last.kind == Facet::Compiler::NodeKind::Nop
      end
      unbounded = parameters.any? do |param|
        {Facet::Compiler::NodeKind::Splat, Facet::Compiler::NodeKind::DoubleSplat}.includes?(param.kind)
      end
      return_node = node.return_type
      return_ref = return_node.try { |value| type_ref(value) }
      name_node = node.name_node
      method = CRA::Psi::Method.new(
        file: @index.current_file,
        name: method_name(node),
        min_arity: required,
        max_arity: unbounded ? nil : parameters.size,
        class_method: name_node ? receiver_name?(name_node) : false,
        owner: owner,
        return_type: return_node.try(&.text) || "Nil",
        return_type_ref: return_ref,
        parameters: parameters.compact_map(&.name).map { |name| name.lstrip('@') },
        location: location_for(node),
        doc: node.doc
      )
      @index.attach(method, owner)
      @index.register_method(method)
    end

    private def add_include(node : Facet::Compiler::SyntaxNode) : Nil
      owner = @owners.last?
      return unless owner
      name = node.callee.try(&.symbol_name)
      return unless name == "include" || name == "extend"
      node.arguments.each do |argument|
        argument.symbol_name.try { |include_name| @index.record_include(owner, include_name) }
      end
    end

    private def add_enum_members(node : Facet::Compiler::SyntaxNode, owner : CRA::Psi::Enum) : Nil
      body = node.body
      return unless body
      body.children.each do |entry|
        candidate = entry.kind == Facet::Compiler::NodeKind::Assign ? entry.target : entry
        next unless candidate
        next unless {Facet::Compiler::NodeKind::Ident, Facet::Compiler::NodeKind::Const}.includes?(candidate.kind)
        name = candidate.symbol_name
        next unless name && !name.empty? && name[0].ascii_uppercase?
        member = CRA::Psi::EnumMember.new(
          file: @index.current_file,
          name: name,
          owner: owner,
          location: location_for(candidate),
          doc: candidate.doc
        )
        @index.attach(member, owner)
      end
    end

    private def type_ref(node : Facet::Compiler::SyntaxNode) : TypeRef?
      case node.kind
      when Facet::Compiler::NodeKind::Ident, Facet::Compiler::NodeKind::Const,
           Facet::Compiler::NodeKind::Path, Facet::Compiler::NodeKind::LiteralNil
        name = node.kind == Facet::Compiler::NodeKind::LiteralNil ? "Nil" : node.symbol_name
        name ? TypeRef.named(name) : nil
      when Facet::Compiler::NodeKind::TypeApply
        name = node.child(0).try(&.symbol_name)
        return nil unless name
        return TypeRef.named("NamedTuple") if name == "NamedTuple"
        args = [] of TypeRef
        (node.child(1).try(&.children) || [] of Facet::Compiler::SyntaxNode).each do |argument|
          if value = type_ref(argument)
            args << value
          end
        end
        TypeRef.named(name, args)
      when Facet::Compiler::NodeKind::Tuple
        args = [] of TypeRef
        node.children.each do |argument|
          if value = type_ref(argument)
            args << value
          end
        end
        TypeRef.named("Tuple", args)
      when Facet::Compiler::NodeKind::NamedTuple
        TypeRef.named("NamedTuple")
      when Facet::Compiler::NodeKind::Binary
        payload = node.raw.payload_index
        return nil unless payload.in?(0...tree.ast.arena.operators.size)
        return nil unless tree.ast.arena.operator_kind(payload) == Facet::Compiler::TokenKind::Pipe
        parts = [] of TypeRef
        node.children.each do |part|
          if value = type_ref(part)
            parts << value
          end
        end
        TypeRef.union(parts)
      when Facet::Compiler::NodeKind::Splat
        node.child(0).try { |value| type_ref(value) }
      else
        node.symbol_name.try { |name| TypeRef.named(name) }
      end
    end

    private def type_vars(node : Facet::Compiler::SyntaxNode) : Array(String)
      name = node.name_node
      return [] of String unless name && name.kind == Facet::Compiler::NodeKind::TypeApply
      (name.child(1).try(&.children) || [] of Facet::Compiler::SyntaxNode).compact_map(&.name)
    end

    private def method_name(node : Facet::Compiler::SyntaxNode) : String
      name = node.name_node
      return node.name.to_s unless name
      while {Facet::Compiler::NodeKind::Path, Facet::Compiler::NodeKind::Binary}.includes?(name.kind)
        name = name.children.last
      end
      name.symbol_name || node.name.to_s
    end

    private def receiver_name?(name : Facet::Compiler::SyntaxNode) : Bool
      {Facet::Compiler::NodeKind::Path, Facet::Compiler::NodeKind::Binary}.includes?(name.kind)
    end

    private def qualified_name(name : String) : String
      return name if name.includes?("::")
      owner = @owners.last?
      owner ? "#{owner.name}::#{name}" : name
    end

    private def module_owner(name : String) : CRA::Psi::Module?
      if owner = @owners.last?.as?(CRA::Psi::Module)
        return owner
      end
      parent_name(name).try { |parent| @index.find_module(parent, true) }
    end

    private def type_owner(name : String) : PsiElement?
      if owner = @owners.last?
        return owner
      end
      parent_name(name).try do |parent|
        @index.find_class(parent) || @index.find_module(parent, true) || @index.find_enum(parent)
      end
    end

    private def parent_name(name : String) : String?
      parts = name.split("::")
      return nil if parts.size < 2
      parts[0...-1].join("::")
    end

    private def location_for(node : Facet::Compiler::SyntaxNode) : Location
      start_position = tree.position_at(node.span.start)
      end_position = tree.position_at(node.span.finish)
      Location.new(start_position.line, start_position.character, end_position.line, end_position.character)
    end

    private def with_owner(owner : PsiElement, &) : Nil
      @owners << owner
      yield
    ensure
      @owners.pop
    end

    private def tree : Facet::Compiler::SyntaxTree
      @tree.not_nil!
    end
  end
end
