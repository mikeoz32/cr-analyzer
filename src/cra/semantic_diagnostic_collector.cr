require "compiler/crystal/syntax"
require "./semantic/alayst"
require "./types"

# Collects semantic diagnostics from lightweight index resolution.
class CRA::SemanticDiagnosticCollector < Crystal::Visitor
  def initialize(@index : CRA::Psi::SemanticIndex, @uri : String, @diagnostics : Array(CRA::Types::Diagnostic))
    @namespace = [] of String
    @class_stack = [] of Crystal::ClassDef
    @def_stack = [] of Crystal::Def
    @type_param_scopes = [] of Array(String)
    @seen = {} of String => Bool
    @type_paths = {} of UInt64 => Bool
  end

  def visit(node : Crystal::ASTNode) : Bool
    true
  end

  def visit(node : Crystal::ModuleDef) : Bool
    with_namespace(node.name.full) do
      with_type_params(node.type_vars || [] of String) do
        node.accept_children(self)
      end
    end
    false
  end

  def visit(node : Crystal::ClassDef) : Bool
    with_namespace(node.name.full) do
      with_type_params(node.type_vars || [] of String) do
        @class_stack << node
        if superclass = node.superclass
          check_type(superclass)
          unless resolvable_type_like?(superclass)
            add_diagnostic(
              node_range(superclass),
              "Unresolved superclass '#{superclass}'"
            )
          end
        end
        node.accept_children(self)
        @class_stack.pop
      end
    end
    false
  end

  def visit(node : Crystal::EnumDef) : Bool
    with_namespace(node.name.full) do
      node.accept_children(self)
    end
    false
  end

  def visit(node : Crystal::Def) : Bool
    with_type_params(def_type_params(node)) do
      @def_stack << node
      if ret = node.return_type
        check_type(ret)
      end
      node.accept_children(self)
      @def_stack.pop
    end
    false
  end

  def visit(node : Crystal::TypeDeclaration) : Bool
    check_type(node.declared_type)
    true
  end

  def visit(node : Crystal::Arg) : Bool
    if restriction = node.restriction
      check_type(restriction)
    end
    true
  end

  def visit(node : Crystal::Alias) : Bool
    check_type(node.value)
    unless resolvable_type_like?(node.value)
      add_diagnostic(
        node_range(node.value),
        "Alias '#{node.name}' references unknown type '#{node.value}'"
      )
    end
    false
  end

  def visit(node : Crystal::Include) : Bool
    check_type(node.name)
    unless resolvable_type_like?(node.name)
      add_diagnostic(
        node_range(node.name),
        "Unresolved include target '#{node.name}'"
      )
    end
    false
  end

  def visit(node : Crystal::Extend) : Bool
    check_type(node.name)
    unless resolvable_type_like?(node.name)
      add_diagnostic(
        node_range(node.name),
        "Unresolved extend target '#{node.name}'"
      )
    end
    false
  end

  def visit(node : Crystal::Call) : Bool
    check_arity(node)
    true
  end

  def visit(node : Crystal::Path) : Bool
    return true if @type_paths[node.object_id]?
    return true unless definitions_for(node).empty?

    if invalid = invalid_enum_member(node)
      add_diagnostic(
        node_range(node),
        "Enum member '#{invalid[:member]}' is not defined in enum '#{invalid[:enum]}'"
      )
      return true
    end

    if segment = unresolved_path_segment(node)
      add_diagnostic(
        node_range(node),
        "Unresolved path segment '#{segment}' in '#{node.full}'"
      )
    end
    true
  end

  private def check_arity(call : Crystal::Call)
    return if {"require", "include", "extend"}.includes?(call.name)

    methods = definitions_for(call).compact_map(&.as?(CRA::Psi::Method))
    return if methods.empty?

    arity = call.args.size + (call.named_args.try(&.size) || 0)
    return if methods.any? { |method| arity_match?(method, arity) }

    add_diagnostic(
      call_name_range(call),
      "No overload matches '#{call.name}' with arity #{arity}"
    )
  end

  private def check_type(type_node : Crystal::ASTNode)
    case type_node
    when Crystal::Path
      @type_paths[type_node.object_id] = true
      return if type_param?(type_node)
      unless resolvable_type_like?(type_node)
        add_diagnostic(
          node_range(type_node),
          "Unknown type '#{type_node}'"
        )
      end
    when Crystal::Generic
      check_type(type_node.name)
      type_node.type_vars.each do |type_var|
        check_type(type_var)
      end
    when Crystal::Union
      type_node.types.each do |union_type|
        check_type(union_type)
      end
    when Crystal::Metaclass
      check_type(type_node.name)
    else
    end
  end

  private def type_param?(node : Crystal::Path) : Bool
    return false unless node.names.size == 1
    name = node.names.first
    @type_param_scopes.reverse_each do |scope|
      return true if scope.includes?(name)
    end
    false
  end

  private def def_type_params(node : Crystal::Def) : Array(String)
    if node.responds_to?(:free_vars)
      node.free_vars || [] of String
    else
      [] of String
    end
  end

  private def invalid_enum_member(node : Crystal::Path) : NamedTuple(enum: String, member: String)?
    names = node.names
    return nil if names.size < 2

    enum_name = names[0...-1].join("::")
    enum_type = @index.resolve_enum_for(
      enum_name,
      node.global? ? nil : current_context,
      node.global?
    )
    return nil unless enum_type

    member = names.last
    return nil if enum_type.members.any? { |candidate| candidate.name == member }
    {enum: enum_type.name, member: member}
  end

  private def unresolved_path_segment(node : Crystal::Path) : String?
    names = node.names
    return nil if names.empty?

    context = node.global? ? nil : current_context
    prefix_name = names.first
    resolved = @index.resolve_type_for(
      node.global? ? "::#{prefix_name}" : prefix_name,
      context,
      @uri
    )
    return prefix_name unless resolved

    current_name = resolved.name
    names[1..].each do |segment|
      candidate = "#{current_name}::#{segment}"
      next_resolved = @index.resolve_type_for(candidate, nil, @uri)
      return segment unless next_resolved
      current_name = next_resolved.name
    end

    nil
  end

  private def resolvable_type_like?(node : Crystal::ASTNode) : Bool
    definitions_for(node).any? do |definition|
      definition.is_a?(CRA::Psi::Class) ||
        definition.is_a?(CRA::Psi::Module) ||
        definition.is_a?(CRA::Psi::Enum) ||
        definition.is_a?(CRA::Psi::Alias)
    end
  end

  private def definitions_for(node : Crystal::ASTNode) : Array(CRA::Psi::PsiElement)
    @index.find_definitions(
      node,
      current_context,
      current_def,
      current_class,
      cursor_for(node),
      @uri
    )
  end

  private def arity_match?(method : CRA::Psi::Method, arity : Int32) : Bool
    return false if arity < method.min_arity
    max = method.max_arity
    return true if max.nil?
    arity <= max
  end

  private def with_namespace(name : String, &)
    if name.includes?("::")
      previous = @namespace
      @namespace = [name]
      begin
        yield
      ensure
        @namespace = previous
      end
    else
      @namespace << name
      begin
        yield
      ensure
        @namespace.pop
      end
    end
  end

  private def with_type_params(type_params : Array(String), &)
    @type_param_scopes << type_params
    yield
  ensure
    @type_param_scopes.pop
  end

  private def current_context : String?
    return nil if @namespace.empty?
    @namespace.join("::")
  end

  private def current_def : Crystal::Def?
    @def_stack.last?
  end

  private def current_class : Crystal::ClassDef?
    @class_stack.last?
  end

  private def cursor_for(node : Crystal::ASTNode) : Crystal::Location?
    node.end_location || node.location
  end

  private def call_name_range(call : Crystal::Call) : CRA::Types::Range?
    name_loc = call.name_location
    return node_range(call) unless name_loc

    CRA::Types::Range.new(
      start_position: CRA::Types::Position.new(line: name_loc.line_number - 1, character: name_loc.column_number - 1),
      end_position: CRA::Types::Position.new(line: name_loc.line_number - 1, character: name_loc.column_number - 1 + call.name.size)
    )
  end

  private def node_range(node : Crystal::ASTNode) : CRA::Types::Range?
    loc = node.location || node.name_location
    end_loc = node.end_location || loc
    return nil unless loc && end_loc

    CRA::Types::Range.new(
      start_position: CRA::Types::Position.new(line: loc.line_number - 1, character: loc.column_number - 1),
      end_position: CRA::Types::Position.new(line: end_loc.line_number - 1, character: end_loc.column_number - 1)
    )
  end

  private def add_diagnostic(range : CRA::Types::Range?, message : String)
    return unless range
    key = "#{range.start_position.line}:#{range.start_position.character}:#{range.end_position.line}:#{range.end_position.character}:#{message}"
    return if @seen[key]?
    @seen[key] = true

    @diagnostics << CRA::Types::Diagnostic.new(
      range: range,
      severity: CRA::Types::DiagnosticSeverity::Warning,
      message: message,
      source: "semantic"
    )
  end
end
