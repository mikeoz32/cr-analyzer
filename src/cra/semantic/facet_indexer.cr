require "facet/compiler"
require "./semantic_index"
require "./facet_type_ref_helper"

module CRA::Psi
  # Declaration-level SemanticIndex producer for Facet's native AST. This is a
  # parallel index during cutover; it intentionally stores semantic names,
  # TypeRefs, and Locations rather than syntax nodes.
  class FacetSemanticIndexer
    include FacetTypeRefHelper

    def initialize(@index : SemanticIndex)
      @owners = [] of PsiElement
      @original_declarations = nil.as(Hash(String, Int32)?)
    end

    def index(tree : Facet::Compiler::SyntaxTree) : Nil
      @original_declarations = nil
      index_tree(tree)
    end

    # Indexes only declarations introduced by macro expansion. The expanded
    # tree contains the complete source, so original declarations are consumed
    # as a multiset instead of being duplicated under a virtual URI.
    def index_generated(
      tree : Facet::Compiler::SyntaxTree,
      original : Facet::Compiler::SyntaxTree,
    ) : Nil
      originals = declaration_counts(original)
      @original_declarations = originals.dup
      @tree = tree
      build_skeleton(tree.root)
      @owners.clear
      @original_declarations = originals.dup
      build_semantics(tree.root)
    ensure
      @owners.clear
      @original_declarations = nil
    end

    private def index_tree(tree : Facet::Compiler::SyntaxTree) : Nil
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
        original = consume_original_declaration(node)
        element = if original
                    @index.find_module(name, true) || @index.ensure_module(name, owner, location_for(node), type_vars(node), node.doc)
                  else
                    @index.ensure_module(name, owner, location_for(node), type_vars(node), node.doc)
                  end
        with_owner(element) { node.body.try { |body| build_skeleton(body) } }
      when Facet::Compiler::NodeKind::Class, Facet::Compiler::NodeKind::Struct
        name = qualified_name(node.name.to_s)
        owner = type_owner(name)
        original = consume_original_declaration(node)
        element = if original
                    @index.find_class(name) || @index.ensure_class(name, owner, location_for(node), type_vars(node), node.doc)
                  else
                    @index.ensure_class(name, owner, location_for(node), type_vars(node), node.doc)
                  end
        with_owner(element) { node.body.try { |body| build_skeleton(body) } }
      when Facet::Compiler::NodeKind::Enum
        name = qualified_name(node.name.to_s)
        owner = type_owner(name)
        original = consume_original_declaration(node)
        element = if original
                    @index.find_enum(name) || @index.ensure_enum(name, owner, location_for(node), node.doc)
                  else
                    @index.ensure_enum(name, owner, location_for(node), node.doc)
                  end
        with_owner(element) { node.body.try { |body| build_skeleton(body) } }
      when Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Fun,
           Facet::Compiler::NodeKind::MacroDef
        # Macro templates are indexed by Facet's ProgramIndex, not as runtime
        # declarations in the editor semantic model. Type declarations inside
        # method bodies are invalid Crystal and must not leak into the skeleton.
      else
        node.children.each { |child| build_skeleton(child) }
      end
    end

    private def build_semantics(node : Facet::Compiler::SyntaxNode) : Nil
      case node.kind
      when Facet::Compiler::NodeKind::Module, Facet::Compiler::NodeKind::Lib
        name = qualified_name(node.name.to_s)
        owner = module_owner(name)
        original = consume_original_declaration(node)
        element = if original
                    @index.find_module(name, true) || @index.ensure_module(name, owner, location_for(node), type_vars(node), node.doc)
                  else
                    @index.ensure_module(name, owner, location_for(node), type_vars(node), node.doc)
                  end
        with_owner(element) { node.body.try { |body| build_semantics(body) } }
      when Facet::Compiler::NodeKind::Class, Facet::Compiler::NodeKind::Struct
        name = qualified_name(node.name.to_s)
        owner = type_owner(name)
        original = consume_original_declaration(node)
        element = if original
                    @index.find_class(name) || @index.ensure_class(name, owner, location_for(node), type_vars(node), node.doc)
                  else
                    @index.ensure_class(name, owner, location_for(node), type_vars(node), node.doc)
                  end
        unless original
          node.superclass.try(&.symbol_name).try { |superclass| @index.set_superclass(element.name, superclass) }
        end
        with_owner(element) { node.body.try { |body| build_semantics(body) } }
      when Facet::Compiler::NodeKind::Enum
        name = qualified_name(node.name.to_s)
        owner = type_owner(name)
        original = consume_original_declaration(node)
        element = if original
                    @index.find_enum(name) || @index.ensure_enum(name, owner, location_for(node), node.doc)
                  else
                    @index.ensure_enum(name, owner, location_for(node), node.doc)
                  end
        add_enum_members(node, element)
        with_owner(element) { node.body.try { |body| build_semantics(body) } }
      when Facet::Compiler::NodeKind::Alias, Facet::Compiler::NodeKind::TypeDef
        unless consume_original_declaration(node)
          name = qualified_name(node.name.to_s)
          target = node.child(1).try { |value| type_ref_from_facet(value) }
          @index.record_alias(name, target, location_for(node), node.doc)
        end
      when Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Fun
        add_method(node) unless consume_original_declaration(node)
      when Facet::Compiler::NodeKind::Call
        add_include(node) unless consume_original_declaration(node)
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
      return_ref = return_node.try { |value| type_ref_from_facet(value) }
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
        next if consume_original_declaration(candidate, "enum-member:#{owner.name}:#{name}")
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
      normalized = name.lchop("::")
      return normalized if name.starts_with?("::") || normalized.includes?("::")
      owner = @owners.last?
      owner ? "#{owner.name}::#{normalized}" : normalized
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

    private def declaration_counts(tree : Facet::Compiler::SyntaxTree) : Hash(String, Int32)
      counts = {} of String => Int32
      collect_declarations(tree.root, "", counts)
      counts
    end

    private def collect_declarations(
      node : Facet::Compiler::SyntaxNode,
      scope : String,
      counts : Hash(String, Int32),
    ) : Nil
      case node.kind
      when Facet::Compiler::NodeKind::Module, Facet::Compiler::NodeKind::Lib,
           Facet::Compiler::NodeKind::Class, Facet::Compiler::NodeKind::Struct,
           Facet::Compiler::NodeKind::Enum
        name = qualified_name_in(scope, node.name.to_s)
        increment_declaration(counts, "type:#{node.kind}:#{name}")
        collect_enum_declarations(node, name, counts) if node.kind == Facet::Compiler::NodeKind::Enum
        node.body.try { |body| collect_declarations(body, name, counts) }
      when Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Fun
        increment_declaration(counts, method_declaration_key(scope, node)) unless scope.empty?
      when Facet::Compiler::NodeKind::Alias, Facet::Compiler::NodeKind::TypeDef
        increment_declaration(counts, "alias:#{qualified_name_in(scope, node.name.to_s)}")
      when Facet::Compiler::NodeKind::Call
        if key = include_declaration_key(scope, node)
          increment_declaration(counts, key)
        end
        node.children.each { |child| collect_declarations(child, scope, counts) }
      when Facet::Compiler::NodeKind::MacroDef
      else
        node.children.each { |child| collect_declarations(child, scope, counts) }
      end
    end

    private def collect_enum_declarations(
      node : Facet::Compiler::SyntaxNode,
      owner_name : String,
      counts : Hash(String, Int32),
    ) : Nil
      node.body.try do |body|
        body.children.each do |entry|
          candidate = entry.kind == Facet::Compiler::NodeKind::Assign ? entry.target : entry
          next unless candidate
          next unless {Facet::Compiler::NodeKind::Ident, Facet::Compiler::NodeKind::Const}.includes?(candidate.kind)
          name = candidate.symbol_name
          next unless name && !name.empty? && name[0].ascii_uppercase?
          increment_declaration(counts, "enum-member:#{owner_name}:#{name}")
        end
      end
    end

    private def increment_declaration(counts : Hash(String, Int32), key : String) : Nil
      counts[key] = (counts[key]? || 0) + 1
    end

    private def consume_original_declaration(
      node : Facet::Compiler::SyntaxNode,
      explicit_key : String? = nil,
    ) : Bool
      counts = @original_declarations
      return false unless counts
      key = explicit_key || declaration_key(node)
      return false unless key
      count = counts[key]? || 0
      return false if count <= 0
      if count == 1
        counts.delete(key)
      else
        counts[key] = count - 1
      end
      true
    end

    private def declaration_key(node : Facet::Compiler::SyntaxNode) : String?
      owner_name = @owners.last?.try(&.name) || ""
      case node.kind
      when Facet::Compiler::NodeKind::Module, Facet::Compiler::NodeKind::Lib,
           Facet::Compiler::NodeKind::Class, Facet::Compiler::NodeKind::Struct,
           Facet::Compiler::NodeKind::Enum
        "type:#{node.kind}:#{qualified_name(node.name.to_s)}"
      when Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Fun
        owner_name.empty? ? nil : method_declaration_key(owner_name, node)
      when Facet::Compiler::NodeKind::Alias, Facet::Compiler::NodeKind::TypeDef
        "alias:#{qualified_name(node.name.to_s)}"
      when Facet::Compiler::NodeKind::Call
        include_declaration_key(owner_name, node)
      else
        nil
      end
    end

    private def method_declaration_key(owner_name : String, node : Facet::Compiler::SyntaxNode) : String
      name_node = node.name_node
      class_method = name_node ? receiver_name?(name_node) : false
      parameters = node.parameters.map do |parameter|
        type = parameter.declared_type.try(&.symbol_name) || parameter.declared_type.try(&.text) || ""
        "#{parameter.kind}:#{parameter.external_name}:#{parameter.name}:#{type}:#{!parameter.value.nil?}"
      end.join("|")
      "method:#{owner_name}:#{class_method}:#{method_name(node)}:#{parameters}"
    end

    private def include_declaration_key(owner_name : String, node : Facet::Compiler::SyntaxNode) : String?
      return nil if owner_name.empty?
      name = node.callee.try(&.symbol_name)
      return nil unless name == "include" || name == "extend"
      arguments = node.arguments.map { |argument| argument.symbol_name || argument.text }.join("|")
      "include:#{owner_name}:#{name}:#{arguments}"
    end

    private def qualified_name_in(scope : String, name : String) : String
      normalized = name.lchop("::")
      return normalized if name.starts_with?("::") || normalized.includes?("::") || scope.empty?
      "#{scope}::#{normalized}"
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
