require "log"
require "./ast"
require "./extensions"
require "../completion"
require "../analysis/macro_interpreter"
require "../analysis/macro_expander"
require "./type_ref_helper"

module CRA::Psi
  class SemanticIndex
    include TypeRefHelper
    include CRA::CompletionProvider

    Log = ::Log.for(self)

    @roots : Array(PsiElement) = [] of PsiElement

    @current_file : String? = nil
    @macro_defs : Hash(String, Hash(String, Array(Crystal::Macro))) = {} of String => Hash(String, Array(Crystal::Macro))
    @macro_expansion_depth : Int32 = 0
    MAX_MACRO_EXPANSION_DEPTH = 4
    # Tracks include/superclass relationships for ancestor method lookups.
    @class_includes : Hash(String, Array(Crystal::ASTNode)) = {} of String => Array(Crystal::ASTNode)
    @module_includes : Hash(String, Array(Crystal::ASTNode)) = {} of String => Array(Crystal::ASTNode)
    @class_superclass : Hash(String, Crystal::ASTNode) = {} of String => Crystal::ASTNode
    @elements_by_file : Hash(String, Array(PsiElement)) = {} of String => Array(PsiElement)
    @type_defs_by_name : Hash(String, Hash(String, TypeDefinition)) = {} of String => Hash(String, TypeDefinition)
    @types_by_file : Hash(String, Array(String)) = {} of String => Array(String)
    @aliases_by_name : Hash(String, Hash(String, CRA::Psi::Alias)) = {} of String => Hash(String, CRA::Psi::Alias)
    @aliases_by_file : Hash(String, Array(String)) = {} of String => Array(String)
    @includes_by_file : Hash(String, Array(IncludeEntry)) = {} of String => Array(IncludeEntry)
    @superclass_defs : Hash(String, Hash(String, Crystal::ASTNode)) = {} of String => Hash(String, Crystal::ASTNode)
    @superclass_by_file : Hash(String, Array(String)) = {} of String => Array(String)
    @dependencies : Hash(String, Hash(String, Bool)) = {} of String => Hash(String, Bool)
    @reverse_dependencies : Hash(String, Hash(String, Bool)) = {} of String => Hash(String, Bool)
    @dependency_sources : Hash(String, Hash(String, Hash(String, Bool))) = {} of String => Hash(String, Hash(String, Bool))
    @deps_by_file : Hash(String, Array(DependencyEdge)) = {} of String => Array(DependencyEdge)

    struct TypeDefinition
      getter kind : Symbol
      getter location : Location?
      getter type_vars : Array(String)

      def initialize(@kind : Symbol, @location : Location?, @type_vars : Array(String))
      end
    end

    struct IncludeEntry
      getter owner_name : String
      getter node : Crystal::ASTNode
      getter kind : Symbol

      def initialize(@owner_name : String, @node : Crystal::ASTNode, @kind : Symbol)
      end
    end

    struct DependencyEdge
      getter owner : String
      getter dependency : String

      def initialize(@owner : String, @dependency : String)
      end
    end

    # Lightweight type hints collected from the current lexical scope.
    class TypeEnv
      getter locals : Hash(String, TypeRef)
      getter ivars : Hash(String, TypeRef)
      getter cvars : Hash(String, TypeRef)

      def initialize
        @locals = {} of String => TypeRef
        @ivars = {} of String => TypeRef
        @cvars = {} of String => TypeRef
      end
    end

    # Collects type hints before the cursor without descending into nested scopes.
    class TypeCollector < Crystal::Visitor
      include TypeRefHelper

      def initialize(
        @env : TypeEnv,
        @cursor : Crystal::Location?,
        @collect_locals : Bool,
        @fill_only : Bool = false
      )
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        return false unless before_cursor?(node)

        if type_ref = type_ref_from_type(node.declared_type)
          assign_type(node.var, type_ref)
        end
        true
      end

      def visit(node : Crystal::Assign) : Bool
        return false unless before_cursor?(node)

        if type_ref = type_ref_from_value(node.value)
          assign_type(node.target, type_ref)
        else
          type_ref = case value = node.value
                     when Crystal::Var
                       @env.locals[value.name]?
                     when Crystal::InstanceVar
                       @env.ivars[value.name]?
                     when Crystal::ClassVar
                       @env.cvars[value.name]?
                     else
                       nil
                     end
          assign_type(node.target, type_ref) if type_ref
        end
        true
      end

      def visit(node : Crystal::OpAssign) : Bool
        return false unless before_cursor?(node)

        if type_ref = type_ref_from_value(node.value)
          assign_type(node.target, type_ref)
        else
          type_ref = case value = node.value
                     when Crystal::Var
                       @env.locals[value.name]?
                     when Crystal::InstanceVar
                       @env.ivars[value.name]?
                     when Crystal::ClassVar
                       @env.cvars[value.name]?
                     else
                       nil
                     end
          assign_type(node.target, type_ref) if type_ref
        end
        true
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

      def register_arg(arg : Crystal::Arg)
        if restriction = arg.restriction
          if type_ref = type_ref_from_type(restriction)
            @env.locals[arg.name] = type_ref
          end
        end
      end

      private def assign_type(target : Crystal::ASTNode, type_ref : TypeRef)
        case target
        when Crystal::Var
          return unless @collect_locals
          return if @fill_only && @env.locals.has_key?(target.name)
          @env.locals[target.name] = type_ref
        when Crystal::InstanceVar
          return if @fill_only && @env.ivars.has_key?(target.name)
          @env.ivars[target.name] = type_ref
        when Crystal::ClassVar
          return if @fill_only && @env.cvars.has_key?(target.name)
          @env.cvars[target.name] = type_ref
        end
      end

      private def before_cursor?(node : Crystal::ASTNode) : Bool
        cursor = @cursor
        return true unless cursor
        loc = node.location
        return true unless loc
        loc.line_number < cursor.line_number ||
          (loc.line_number == cursor.line_number && loc.column_number <= cursor.column_number)
      end
    end

    # Collects instance variable assignments inside initialize methods.
    class InitializeCollector < Crystal::Visitor
      def initialize(@collector : TypeCollector)
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::Def) : Bool
        return false unless node.name == "initialize"
        node.args.each { |arg| @collector.register_arg(arg) }
        node.body.accept(@collector)
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

    # Collects instance/class variable assignments from all method bodies in a class.
    class DefIvarCollector < Crystal::Visitor
      def initialize(@collector : TypeCollector)
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::Def) : Bool
        node.body.accept(@collector)
        false
      end

      def visit(node : Crystal::ClassDef) : Bool
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        false
      end

      def visit(node : Crystal::EnumDef) : Bool
        false
      end

      def visit(node : Crystal::Macro) : Bool
        false
      end
    end

    # Collects local variable definitions in a def body (args, assigns, type declarations).
    class LocalVarCollector < Crystal::Visitor
      def initialize(@definitions : Hash(String, Crystal::ASTNode), @cursor : Crystal::Location?)
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::Assign) : Bool
        return false unless before_cursor?(node)
        record_target(node.target)
        true
      end

      def visit(node : Crystal::MultiAssign) : Bool
        return false unless before_cursor?(node)
        node.targets.each { |target| record_target(target) }
        true
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        return false unless before_cursor?(node)
        record_target(node.var)
        true
      end

      def visit(node : Crystal::Block) : Bool
        return false unless cursor_in?(node)
        node.args.each do |arg|
          name = arg.name
          next if name.empty?
          @definitions[name] = arg
        end
        true
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

      private def record_target(target : Crystal::ASTNode)
        case target
        when Crystal::Var
          return if target.name.empty?
          @definitions[target.name] = target
        when Crystal::TupleLiteral
          target.elements.each { |elem| record_target(elem) }
        end
      end

      private def before_cursor?(node : Crystal::ASTNode) : Bool
        cursor = @cursor
        return true unless cursor
        loc = node.location
        return true unless loc
        loc.line_number < cursor.line_number ||
          (loc.line_number == cursor.line_number && loc.column_number <= cursor.column_number)
      end

      private def cursor_in?(node : Crystal::ASTNode) : Bool
        cursor = @cursor
        return false unless cursor
        start_loc = node.location
        return false unless start_loc
        end_loc = node.end_location || start_loc
        (cursor.line_number > start_loc.line_number ||
          (cursor.line_number == start_loc.line_number && cursor.column_number >= start_loc.column_number)) &&
          (cursor.line_number < end_loc.line_number ||
            (cursor.line_number == end_loc.line_number && cursor.column_number <= end_loc.column_number))
      end
    end

    # Finds the first instance variable definition (assign or type declaration).
    class InstanceVarDefinitionCollector < Crystal::Visitor
      getter definition : Crystal::ASTNode?

      def initialize(@name : String, @cursor : Crystal::Location?, @include_initialize : Bool)
      end

      def visit(node : Crystal::ASTNode) : Bool
        return false if @definition
        true
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        return false unless before_cursor?(node)
        record_target(node.var)
        true
      end

      def visit(node : Crystal::Assign) : Bool
        return false unless before_cursor?(node)
        record_target(node.target)
        true
      end

      def visit(node : Crystal::MultiAssign) : Bool
        return false unless before_cursor?(node)
        node.targets.each { |target| record_target(target) }
        true
      end

      def visit(node : Crystal::OpAssign) : Bool
        return false unless before_cursor?(node)
        record_target(node.target)
        true
      end

      def visit(node : Crystal::Def) : Bool
        return false unless @include_initialize && node.name == "initialize"
        node.body.accept(self)
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

      private def record_target(target : Crystal::ASTNode)
        return if @definition
        case target
        when Crystal::InstanceVar
          if target.name == @name
            @definition = target
          end
        when Crystal::TupleLiteral
          target.elements.each { |elem| record_target(elem) }
        end
      end

      private def before_cursor?(node : Crystal::ASTNode) : Bool
        cursor = @cursor
        return true unless cursor
        loc = node.location
        return true unless loc
        loc.line_number < cursor.line_number ||
          (loc.line_number == cursor.line_number && loc.column_number <= cursor.column_number)
      end
    end

    # Collects instance variable names within a class scope.
    class InstanceVarNameCollector < Crystal::Visitor
      getter names : Hash(String, Crystal::ASTNode)

      def initialize
        @names = {} of String => Crystal::ASTNode
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::InstanceVar) : Bool
        name = node.name
        @names[name] = node unless name.empty?
        true
      end

      def visit(node : Crystal::ClassDef) : Bool
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        false
      end

      def visit(node : Crystal::EnumDef) : Bool
        false
      end

      def visit(node : Crystal::Macro) : Bool
        false
      end
    end

    # Collects class variable names within a class scope.
    class ClassVarNameCollector < Crystal::Visitor
      getter names : Hash(String, Crystal::ASTNode)

      def initialize
        @names = {} of String => Crystal::ASTNode
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::ClassVar) : Bool
        name = node.name
        @names[name] = node unless name.empty?
        true
      end

      def visit(node : Crystal::ClassDef) : Bool
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        false
      end

      def visit(node : Crystal::EnumDef) : Bool
        false
      end

      def visit(node : Crystal::Macro) : Bool
        false
      end
    end

    getter current_file : String?

    def with_current_file(file : String, &)
      old_file = @current_file
      @current_file = file
      yield
    ensure
      @current_file = old_file
    end

    def enter(file : String)
      @current_file = file
    end

    def index(program : Crystal::ASTNode)
      SkeletonIndexer.new(self).index(program)

      if @current_file
        program.accept(MacroRegistry.new(self))
        @macro_expansion_depth = 0
        expander = SemanticIndexer.new(self, expand_macros: true)
        program.accept(MacroPreExpander.new(self, expander))
      end

      SemanticIndexer.new(self, expand_macros: false).index(program)
    end

    def ensure_module(
      name : String,
      owner : CRA::Psi::Module?,
      location : Location?,
      type_vars : Array(String) = [] of String,
      doc : String? = nil
    ) : CRA::Psi::Module
      if found = find_module(name)
        assign_doc(found, doc)
        record_type_definition(name, :module, location, found, type_vars)
        return found
      end
      module_element = CRA::Psi::Module.new(
        file: @current_file,
        name: name,
        classes: [] of CRA::Psi::Class,
        methods: [] of CRA::Psi::Method,
        owner: owner,
        location: location,
        doc: doc
      )
      record_type_definition(name, :module, location, module_element, type_vars)
      attach module_element, owner
      module_element
    end

    def ensure_class(
      name : String,
      owner : CRA::Psi::PsiElement | Nil,
      location : Location?,
      type_vars : Array(String) = [] of String,
      doc : String? = nil
    ) : CRA::Psi::Class
      if found = find_class(name)
        assign_doc(found, doc)
        record_type_definition(name, :class, location, found, type_vars)
        return found
      end
      class_element = CRA::Psi::Class.new(
        file: @current_file,
        name: name,
        owner: owner,
        location: location,
        doc: doc
      )
      record_type_definition(name, :class, location, class_element, type_vars)
      attach class_element, owner
      class_element
    end

    def ensure_enum(
      name : String,
      owner : CRA::Psi::PsiElement | Nil,
      location : Location?,
      doc : String? = nil
    ) : CRA::Psi::Enum
      if found = find_enum(name)
        assign_doc(found, doc)
        record_type_definition(name, :enum, location, found, [] of String)
        return found
      end
      enum_element = CRA::Psi::Enum.new(
        file: @current_file,
        name: name,
        members: [] of CRA::Psi::EnumMember,
        methods: [] of CRA::Psi::Method,
        owner: owner,
        location: location,
        doc: doc
      )
      record_type_definition(name, :enum, location, enum_element, [] of String)
      attach enum_element, owner
      enum_element
    end

    def attach(element : PsiElement, owner : PsiElement?)
      track_element(element)
      if owner.nil?
        @roots << element
        return
      end

      case owner
      when CRA::Psi::Module
        case element
        when CRA::Psi::Module
          @roots << element unless @roots.includes?(element)
        when CRA::Psi::Class
          owner.classes << element
        when CRA::Psi::Method
          owner.methods << element
        when CRA::Psi::Enum
          @roots << element unless @roots.includes?(element)
        end
      when CRA::Psi::Class
        case element
        when CRA::Psi::Method
          owner.methods << element
        when CRA::Psi::Class, CRA::Psi::Module, CRA::Psi::Enum
          @roots << element unless @roots.includes?(element)
        end
      when CRA::Psi::Enum
        case element
        when CRA::Psi::Method
          owner.methods << element
        when CRA::Psi::EnumMember
          owner.members << element
        when CRA::Psi::Class, CRA::Psi::Module, CRA::Psi::Enum
          @roots << element unless @roots.includes?(element)
        end
      end
    end

    def record_include(owner : PsiElement, include_node : Crystal::ASTNode)
      file = @current_file
      case owner
      when CRA::Psi::Class
        add_include(@class_includes, owner.name, include_node)
        if file
          (@includes_by_file[file] ||= [] of IncludeEntry) << IncludeEntry.new(owner.name, include_node, :class)
        end
      when CRA::Psi::Module
        add_include(@module_includes, owner.name, include_node)
        if file
          (@includes_by_file[file] ||= [] of IncludeEntry) << IncludeEntry.new(owner.name, include_node, :module)
        end
      end

      if dependency = dependency_name_for(include_node, owner.name)
        record_dependency(owner.name, dependency)
      end
    end

    def set_superclass(name : String, superclass : Crystal::ASTNode)
      file = @current_file
      if file
        defs = (@superclass_defs[name] ||= {} of String => Crystal::ASTNode)
        defs[file] = superclass
        @class_superclass[name] = superclass
        owners = (@superclass_by_file[file] ||= [] of String)
        owners << name unless owners.includes?(name)
      else
        @class_superclass[name] ||= superclass
      end

      if dependency = dependency_name_for(superclass, parent_namespace(name))
        record_dependency(name, dependency)
      end
    end

    def location_for(node : Crystal::ASTNode) : Location
      if loc = node.location
        end_loc = node.end_location
        start_line = loc.line_number - 1
        start_col = loc.column_number - 1
        end_line = (end_loc.try(&.line_number) || loc.line_number) - 1
        end_col = (end_loc.try(&.column_number) || loc.column_number) - 1
        Location.new(start_line, start_col, end_line, end_col)
      else
        Location.new(0, 0, 0, 0)
      end
    end

    def remove_file(file : String)
      if elements = @elements_by_file.delete(file)
        elements.each { |element| detach(element) }
      end

      if includes = @includes_by_file.delete(file)
        includes.each do |entry|
          store = entry.kind == :class ? @class_includes : @module_includes
          if nodes = store[entry.owner_name]?
            nodes.delete(entry.node)
            store.delete(entry.owner_name) if nodes.empty?
          end
        end
      end

      if owners = @superclass_by_file.delete(file)
        owners.each do |owner|
          if defs = @superclass_defs[owner]?
            defs.delete(file)
            if defs.empty?
              @superclass_defs.delete(owner)
              @class_superclass.delete(owner)
            else
              @class_superclass[owner] = defs.values.first
            end
          end
        end
      end

      if edges = @deps_by_file.delete(file)
        edges.each { |edge| remove_dependency(edge.owner, edge.dependency, file) }
      end

      if type_names = @types_by_file.delete(file)
        type_names.each { |name| remove_type_definition(name, file) }
      end

      if alias_names = @aliases_by_file.delete(file)
        alias_names.each { |name| remove_alias_definition(name, file) }
      end
    end

    def type_names_for_file(file : String) : Array(String)
      @types_by_file[file]? || [] of String
    end

    def dependent_types_for(types : Array(String)) : Array(String)
      queue = types.dup
      visited = {} of String => Bool
      results = [] of String

      idx = 0
      while idx < queue.size
        current = queue[idx]
        idx += 1
        if deps = @reverse_dependencies[current]?
          deps.each_key do |dependent|
            next if visited[dependent]?
            visited[dependent] = true
            results << dependent
            queue << dependent
          end
        end
      end
      results
    end

    def files_for_types(types : Array(String)) : Array(String)
      files = [] of String
      types.each do |name|
        if defs = @type_defs_by_name[name]?
          defs.each_key { |file| files << file }
        end
      end
      files.uniq
    end

    private def track_element(element : PsiElement)
      return if element.is_a?(CRA::Psi::Module) || element.is_a?(CRA::Psi::Class) || element.is_a?(CRA::Psi::Enum)
      file = element.file
      return unless file
      (@elements_by_file[file] ||= [] of PsiElement) << element
    end

    private def record_type_definition(
      name : String,
      kind : Symbol,
      location : Location?,
      element : PsiElement,
      type_vars : Array(String) = [] of String
    )
      file = @current_file
      return unless file

      defs = (@type_defs_by_name[name] ||= {} of String => TypeDefinition)
      defs[file] = TypeDefinition.new(kind, location, type_vars)

      names = (@types_by_file[file] ||= [] of String)
      names << name unless names.includes?(name)

      if element.file.nil? || element.file == file
        element.file = file
        element.location = location if location
      end
    end

    private def assign_doc(element : PsiElement, doc : String?)
      return if doc.nil? || doc.empty?
      return if element.doc
      element.doc = doc
    end

    def record_alias(name : String, target : TypeRef?, location : Location?, doc : String? = nil)
      file = @current_file
      return unless file

      alias_element = CRA::Psi::Alias.new(
        file: file,
        name: name,
        target: target,
        location: location,
        doc: doc
      )

      defs = (@aliases_by_name[name] ||= {} of String => CRA::Psi::Alias)
      defs[file] = alias_element

      names = (@aliases_by_file[file] ||= [] of String)
      names << name unless names.includes?(name)
    end

    private def remove_alias_definition(name : String, file : String)
      defs = @aliases_by_name[name]?
      return unless defs
      defs.delete(file)
      @aliases_by_name.delete(name) if defs.empty?
    end

    private def find_alias(name : String, file : String? = nil) : CRA::Psi::Alias?
      defs = @aliases_by_name[name]?
      return nil unless defs
      return defs[file] if file && defs[file]?
      defs.values.first?
    end

    private def resolve_alias_in_context(name : String, context : String?, file : String? = nil) : CRA::Psi::Alias?
      return find_alias(name, file) if name.includes?("::")

      if context && !context.empty?
        parts = context.split("::")
        while parts.size > 0
          candidate = (parts + [name]).join("::")
          if resolved = find_alias(candidate, file)
            return resolved
          end
          parts.pop
        end
      end
      find_alias(name, file)
    end

    private def remove_type_definition(name : String, file : String)
      defs = @type_defs_by_name[name]?
      return unless defs

      defs.delete(file)
      if defs.empty?
        @type_defs_by_name.delete(name)
        if element = find_type(name)
          detach(element)
        end
        return
      end

      if element = find_type(name)
        if element.file.nil? || element.file == file
          new_file, defn = defs.first
          element.file = new_file
          element.location = defn.location
        end
      end
    end

    private def dependency_name_for(node : Crystal::ASTNode, context : String?) : String?
      if resolved = resolve_type_node(node, context)
        return resolved.name
      end

      case node
      when Crystal::Path
        name = node.full
        return name if node.global?
        if context && !context.empty? && !name.includes?("::")
          if scope = parent_namespace(context)
            return "#{scope}::#{name}"
          end
        end
        name
      when Crystal::Generic
        dependency_name_for(node.name, context)
      when Crystal::Metaclass
        dependency_name_for(node.name, context)
      else
        nil
      end
    end

    private def parent_namespace(name : String) : String?
      parts = name.split("::")
      return nil if parts.size < 2
      parts[0...-1].join("::")
    end

    private def record_dependency(owner : String, dependency : String)
      return if owner.empty? || dependency.empty?
      file = @current_file
      return unless file

      sources = (@dependency_sources[owner] ||= {} of String => Hash(String, Bool))
      files = (sources[dependency] ||= {} of String => Bool)
      return if files[file]?

      files[file] = true
      (@dependencies[owner] ||= {} of String => Bool)[dependency] = true
      (@reverse_dependencies[dependency] ||= {} of String => Bool)[owner] = true
      (@deps_by_file[file] ||= [] of DependencyEdge) << DependencyEdge.new(owner, dependency)
    end

    private def remove_dependency(owner : String, dependency : String, file : String)
      sources = @dependency_sources[owner]?
      return unless sources
      files = sources[dependency]?
      return unless files

      files.delete(file)
      unless files.empty?
        return
      end

      sources.delete(dependency)
      @dependency_sources.delete(owner) if sources.empty?

      if deps = @dependencies[owner]?
        deps.delete(dependency)
        @dependencies.delete(owner) if deps.empty?
      end
      if reverse = @reverse_dependencies[dependency]?
        reverse.delete(owner)
        @reverse_dependencies.delete(dependency) if reverse.empty?
      end
    end

    private def detach(element : PsiElement)
      owner = case element
              when CRA::Psi::Method
                element.owner
              when CRA::Psi::Class
                element.owner
              when CRA::Psi::Enum
                element.owner
              when CRA::Psi::EnumMember
                element.owner
              when CRA::Psi::Module
                element.owner
              else
                nil
              end

      if owner.nil?
        @roots.delete(element)
        return
      end

      case owner
      when CRA::Psi::Module
        case element
        when CRA::Psi::Class
          owner.classes.delete(element)
        when CRA::Psi::Method
          owner.methods.delete(element)
        when CRA::Psi::Module, CRA::Psi::Enum
          @roots.delete(element)
        end
      when CRA::Psi::Class
        case element
        when CRA::Psi::Method
          owner.methods.delete(element)
        else
          @roots.delete(element)
        end
      when CRA::Psi::Enum
        case element
        when CRA::Psi::Method
          owner.methods.delete(element)
        when CRA::Psi::EnumMember
          owner.members.delete(element)
        else
          @roots.delete(element)
        end
      end
    end

    def find_module(name : String, create_on_missing : Bool = false) : CRA::Psi::Module?
      @roots.each do |root|
        if root.is_a?(CRA::Psi::Module) && root.name == name
          return root.as(CRA::Psi::Module)
        end
      end
      nil unless create_on_missing
      if create_on_missing
        module_element = CRA::Psi::Module.new(
          file: @current_file,
          name: name,
          classes: [] of CRA::Psi::Class,
          methods: [] of CRA::Psi::Method,
          owner: nil
        )
        record_type_definition(name, :module, nil, module_element)
        @roots << module_element
        return module_element
      end
    end

    def find_class(name : String) : CRA::Psi::Class?
      @roots.each do |root|
        if root.is_a?(CRA::Psi::Class) && root.name == name
          return root.as(CRA::Psi::Class)
        end
        if root.is_a?(CRA::Psi::Module)
          root.classes.each do |cls|
            if cls.name == name
              return cls
            end
          end
        end
      end
      nil
    end

    def find_enum(name : String) : CRA::Psi::Enum?
      @roots.each do |root|
        if root.is_a?(CRA::Psi::Enum) && root.name == name
          return root.as(CRA::Psi::Enum)
        end
      end
      nil
    end

    private def find_type(name : String) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      find_class(name) || find_module(name) || find_enum(name)
    end

    private def find_methods_in(owner : CRA::Psi::PsiElement, name : String, class_method : Bool? = nil) : Array(Method)
      case owner
      when CRA::Psi::Module, CRA::Psi::Class, CRA::Psi::Enum
        methods = owner.methods.select { |meth| meth.name == name }
        return methods if class_method.nil?
        methods.select { |meth| meth.class_method == class_method }
      else
        [] of CRA::Psi::Method
      end
    end

    private def type_definition_elements(name : String) : Array(PsiElement)
      results = [] of PsiElement
      element = find_type(name)
      if defs = @type_defs_by_name[name]?
        defs.each do |file, defn|
          next unless defn.location
          if element && element.file == file
            results << element
          else
            results << CRA::Psi::PsiElement.new(file, name, defn.location)
          end
        end
      end
      results
    end

    def register_macro_in_scope(node : Crystal::Macro, scope : String)
      @macro_defs[scope] ||= {} of String => Array(Crystal::Macro)
      @macro_defs[scope][node.name] ||= [] of Crystal::Macro
      @macro_defs[scope][node.name] << node
    end

    def expand_macro_call_in_scope(node : Crystal::Call, scope : String, indexer : SemanticIndexer)
      return unless node.obj.nil?
      return if @macro_expansion_depth >= MAX_MACRO_EXPANSION_DEPTH

      owner : PsiElement? = nil
      if indexer.owner_stack_empty? && !scope.empty?
        owner = find_type(scope)
      end

      if macro_def = find_macro(node.name, scope, node)
        expand_user_macro(macro_def, node, owner, indexer)
        return
      end

      if file = @current_file
        if expansion = CRA::Analysis::MacroExpander.expand_builtin(node, file)
          expand_virtual(expansion, owner, indexer)
        end
      end
    end

    private def expand_user_macro(macro_def : Crystal::Macro, call : Crystal::Call, owner : PsiElement?, indexer : SemanticIndexer)
      content = CRA::Analysis::MacroInterpreter.new(macro_def, call).interpret
      return if content.empty?

      macro_uri = macro_uri_for(call)
      expand_virtual({macro_uri, content}, owner, indexer)
    rescue ex
      Log.info { "Macro expansion failed for #{call.name}: #{ex.message}" }
    end

    private def expand_virtual(expansion : {String, String}, owner : PsiElement?, indexer : SemanticIndexer)
      uri, content = expansion
      parser = Crystal::Parser.new(content)
      expanded_node = parser.parse

      @macro_expansion_depth += 1
      begin
        indexer.index_virtual(expanded_node, uri, owner)
      ensure
        @macro_expansion_depth -= 1
      end
    rescue ex : Crystal::SyntaxException
      Log.info { "Error parsing expanded macro: #{ex.message}" }
    end

    private def macro_uri_for(call : Crystal::Call) : String
      file = @current_file || "file://"
      line = call.location.try(&.line_number) || 0
      col = call.location.try(&.column_number) || 0
      "crystal-macro:#{file.sub("file://", "")}/#{call.name}/#{line}_#{col}.cr"
    end

    private def find_macro(name : String, context : String, call : Crystal::Call) : Crystal::Macro?
      scopes = [] of String
      if !context.empty?
        parts = context.split("::")
        while parts.size > 0
          scopes << parts.join("::")
          parts.pop
        end
      end
      scopes << ""

      scopes.each do |scope|
        if scope_defs = @macro_defs[scope]?
          if defs = scope_defs[name]?
            if selected = select_macro_def(defs, call)
              return selected
            end
          end
        end
      end
      nil
    end

    private def select_macro_def(defs : Array(Crystal::Macro), call : Crystal::Call) : Crystal::Macro?
      defs.each do |macro_def|
        return macro_def if macro_matches_call?(macro_def, call)
      end
      defs.first?
    end

    private def macro_matches_call?(macro_def : Crystal::Macro, call : Crystal::Call) : Bool
      arity = macro_arity(macro_def)
      call_arity = call.args.size
      return false if call_arity < arity[:min]
      max = arity[:max]
      return true if max.nil?
      call_arity <= max
    end

    private def macro_arity(macro_def : Crystal::Macro) : {min: Int32, max: Int32?}
      splat_index = macro_def.splat_index
      required = 0
      macro_def.args.each_with_index do |arg, idx|
        next if splat_index && idx == splat_index
        required += 1 unless arg.default_value
      end
      max = splat_index ? nil : macro_def.args.size
      {min: required, max: max}
    end

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

    def complete(context : CRA::CompletionContext) : Array(CRA::Types::CompletionItem)
      return [] of CRA::Types::CompletionItem if context.require_prefix

      trigger = context.trigger_character
      case trigger
      when "."
        prefix = context.member_prefix(trigger)
        receiver = receiver_for_dot(context, prefix)
        return complete_members(context, prefix, receiver)
      when "::"
        namespace = namespace_completion_data(context).try(&.[](:namespace))
        return complete_namespace(context, context.member_prefix(trigger), namespace)
      when "@"
        return complete_instance_vars(context, context.member_prefix(trigger))
      end

      if data = namespace_completion_data(context)
        return complete_namespace(context, data[:prefix], data[:namespace])
      end

      if call = context.node.as?(Crystal::Call) || context.previous_node.as?(Crystal::Call)
        if receiver = call.obj
          return complete_members(context, context.word_prefix, receiver)
        end
      end

      complete_general(context)
    end

    private def add_include(store : Hash(String, Array(Crystal::ASTNode)), owner_name : String, include_node : Crystal::ASTNode)
      store[owner_name] ||= [] of Crystal::ASTNode
      store[owner_name] << include_node
    end

    # Builds a local type env from class-level declarations, initialize, and the current def.
    private def build_type_env(scope_def : Crystal::Def?, scope_class : Crystal::ClassDef?, cursor : Crystal::Location?) : TypeEnv
      env = TypeEnv.new
      if scope_class
        # Collect ivar declarations and assignments at class level.
        scope_class.body.accept(TypeCollector.new(env, nil, false))
        # Also consider ivars initialized in initialize.
        scope_class.body.accept(InitializeCollector.new(TypeCollector.new(env, nil, false)))
        # Fill missing ivars/cvars from other method bodies (best-effort).
        scope_class.body.accept(DefIvarCollector.new(TypeCollector.new(env, nil, false, true)))
      end
      if scope_def
        scope_def.args.each do |arg|
          if restriction = arg.restriction
            if type_ref = type_ref_from_type(restriction)
              env.locals[arg.name] = type_ref
            end
          end
        end
        scope_def.body.accept(TypeCollector.new(env, cursor, true))
      end
      env
    end

    private def complete_members(
      context : CRA::CompletionContext,
      prefix : String,
      receiver_node : Crystal::ASTNode? = nil
    ) : Array(CRA::Types::CompletionItem)
      receiver = receiver_node || receiver_node_for_completion(context.node) || receiver_node_for_completion(context.previous_node)
      return [] of CRA::Types::CompletionItem unless receiver

      owner_info = resolve_receiver_owner(
        receiver,
        context.enclosing_type_name,
        context.enclosing_def,
        context.enclosing_class,
        context.cursor_location
      )
      return [] of CRA::Types::CompletionItem unless owner_info

      owner, class_method = owner_info
      methods = methods_with_ancestors(owner, class_method)
      items = [] of CRA::Types::CompletionItem
      seen = {} of String => Bool
      methods.each do |method|
        next unless method.name.starts_with?(prefix)
        next if seen[method.name]?
        seen[method.name] = true
        items << CRA::Types::CompletionItem.new(
          label: method.name,
          kind: CRA::Types::CompletionItemKind::Method,
          detail: method_detail(method)
        )
      end
      items
    end

    private def complete_namespace(
      context : CRA::CompletionContext,
      prefix : String,
      namespace_hint : String? = nil
    ) : Array(CRA::Types::CompletionItem)
      namespace = namespace_hint
      unless namespace
        if data = namespace_completion_data(context)
          namespace = data[:namespace]
          prefix = data[:prefix]
        end
      end
      return [] of CRA::Types::CompletionItem unless namespace

      resolved = resolve_type_name(namespace, context.enclosing_type_name)
      namespace_name = resolved.try(&.name) || namespace

      items = [] of CRA::Types::CompletionItem
      seen = {} of String => Bool

      if enum_type = resolved.as?(CRA::Psi::Enum)
        enum_type.members.each do |member|
          next unless member.name.starts_with?(prefix)
          next if seen[member.name]?
          seen[member.name] = true
          items << CRA::Types::CompletionItem.new(
            label: member.name,
            kind: CRA::Types::CompletionItemKind::EnumMember,
            detail: enum_type.name
          )
        end
      end

      type_candidates(namespace_name).each do |label, full_name|
        next unless label.starts_with?(prefix)
        next if seen[label]?
        seen[label] = true
        items << CRA::Types::CompletionItem.new(
          label: label,
          kind: completion_kind_for_type(full_name),
          detail: type_signature_for(full_name)
        )
      end

      items
    end

    private def complete_instance_vars(context : CRA::CompletionContext, prefix : String) : Array(CRA::Types::CompletionItem)
      scope_class = context.enclosing_class
      return [] of CRA::Types::CompletionItem unless scope_class

      if prefix.starts_with?("@@")
        return complete_class_vars(scope_class, prefix, context)
      end

      collector = InstanceVarNameCollector.new
      scope_class.body.accept(collector)
      replace_range = replacement_range(context, prefix)
      items = [] of CRA::Types::CompletionItem
      seen = {} of String => Bool
      collector.names.each_key do |name|
        next unless name.starts_with?(prefix)
        next if seen[name]?
        seen[name] = true
        items << CRA::Types::CompletionItem.new(
          label: name,
          kind: CRA::Types::CompletionItemKind::Property,
          text_edit: CRA::Types::TextEdit.new(replace_range, name)
        )
      end
      items
    end

    private def complete_class_vars(
      scope_class : Crystal::ClassDef,
      prefix : String,
      context : CRA::CompletionContext
    ) : Array(CRA::Types::CompletionItem)
      collector = ClassVarNameCollector.new
      scope_class.body.accept(collector)
      replace_range = replacement_range(context, prefix)
      items = [] of CRA::Types::CompletionItem
      seen = {} of String => Bool
      collector.names.each_key do |name|
        next unless name.starts_with?(prefix)
        next if seen[name]?
        seen[name] = true
        items << CRA::Types::CompletionItem.new(
          label: name,
          kind: CRA::Types::CompletionItemKind::Variable,
          text_edit: CRA::Types::TextEdit.new(replace_range, name)
        )
      end
      items
    end

    private def complete_general(context : CRA::CompletionContext) : Array(CRA::Types::CompletionItem)
      prefix = context.word_prefix
      items = [] of CRA::Types::CompletionItem

      if prefix.starts_with?("@@")
        if scope_class = context.enclosing_class
          return complete_class_vars(scope_class, prefix, context)
        end
      elsif prefix.starts_with?("@")
        return complete_instance_vars(context, prefix)
      end

      if scope_def = context.enclosing_def
        local_definitions(scope_def, context.cursor_location).each_key do |name|
          next unless name.starts_with?(prefix)
          items << CRA::Types::CompletionItem.new(
            label: name,
            kind: CRA::Types::CompletionItemKind::Variable
          )
        end
      end

      namespace = parent_namespace(context.enclosing_type_name || "")
      type_candidates(namespace, include_global: true).each do |label, full_name|
        next unless label.starts_with?(prefix)
        items << CRA::Types::CompletionItem.new(
          label: label,
          kind: completion_kind_for_type(full_name),
          detail: type_signature_for(full_name)
        )
      end

      items
    end

    private def type_candidates(namespace : String?, include_global : Bool = false) : Hash(String, String)
      results = {} of String => String
      if namespace && !namespace.empty?
        prefix = "#{namespace}::"
        @aliases_by_name.each_key do |name|
          next unless name.starts_with?(prefix)
          remainder = name[prefix.size..-1]? || ""
          next if remainder.empty?
          label = remainder.split("::").first
          full_name = "#{namespace}::#{label}"
          results[label] ||= full_name
        end
        @type_defs_by_name.each_key do |name|
          next unless name.starts_with?(prefix)
          remainder = name[prefix.size..-1]? || ""
          next if remainder.empty?
          label = remainder.split("::").first
          full_name = "#{namespace}::#{label}"
          results[label] ||= full_name
        end
      end

      if include_global || namespace.nil? || namespace.empty?
        @aliases_by_name.each_key do |name|
          next if name.includes?("::")
          results[name] ||= name
        end
        @type_defs_by_name.each_key do |name|
          next if name.includes?("::")
          results[name] ||= name
        end
      end
      results
    end

    private def completion_kind_for_type(full_name : String) : CRA::Types::CompletionItemKind
      if @aliases_by_name[full_name]?
        return CRA::Types::CompletionItemKind::Class
      end
      if defs = @type_defs_by_name[full_name]?
        kind = defs.values.first.kind
        return CRA::Types::CompletionItemKind::Module if kind == :module
        return CRA::Types::CompletionItemKind::Enum if kind == :enum
      end
      CRA::Types::CompletionItemKind::Class
    end

    def type_signature_for(full_name : String) : String
      if alias_def = find_alias(full_name)
        if target = alias_def.target
          return "alias #{full_name} = #{target.display}"
        end
        return "alias #{full_name}"
      end
      if defs = @type_defs_by_name[full_name]?
        type_vars = defs.values.first.type_vars
        return full_name if type_vars.empty?
        return "#{full_name}(#{type_vars.join(", ")})"
      end
      full_name
    end

    private def receiver_node_for_completion(
      node : Crystal::ASTNode?,
      prefer_call : Bool = false
    ) : Crystal::ASTNode?
      case node
      when Crystal::Call
        return node if prefer_call
        node.obj
      when Crystal::Var, Crystal::InstanceVar, Crystal::ClassVar, Crystal::Path, Crystal::Generic, Crystal::Metaclass, Crystal::Self
        node
      else
        nil
      end
    end

    private def receiver_for_dot(
      context : CRA::CompletionContext,
      prefix : String
    ) : Crystal::ASTNode?
      call = context.node.as?(Crystal::Call) || context.previous_node.as?(Crystal::Call)
      if call
        receiver = call.obj
        return receiver unless prefix.empty?

        if name_loc = call.name_location
          if cursor = context.cursor_location
            if location_before?(cursor, name_loc)
              return receiver
            end
          end
        end
        return call
      end

      receiver_node_for_completion(context.node) || receiver_node_for_completion(context.previous_node)
    end

    private def location_before?(left : Crystal::Location, right : Crystal::Location) : Bool
      left.line_number < right.line_number ||
        (left.line_number == right.line_number && left.column_number <= right.column_number)
    end

    private def resolve_receiver_owner(
      receiver : Crystal::ASTNode?,
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?
    ) : {CRA::Psi::PsiElement, Bool}?
      return nil unless receiver || context

      type_env : TypeEnv? = nil
      case receiver
      when Crystal::Self
        if context && (owner = find_type(context))
          in_class_method = scope_def && scope_def.receiver
          return {owner, in_class_method ? true : false}
        end
      when Crystal::Path, Crystal::Generic, Crystal::Metaclass
        if owner = resolve_type_node(receiver, context)
          return {owner, true}
        end
      when Crystal::Call
        if type_ref = infer_type_ref(receiver, context, scope_def, scope_class, cursor)
          if owner = resolve_type_ref(type_ref, context)
            return {owner, false}
          end
        end
      when Crystal::Var
        type_env ||= build_type_env(scope_def, scope_class, cursor)
        if type_ref = type_env.locals[receiver.name]?
          if owner = resolve_type_ref(type_ref, context)
            return {owner, false}
          end
        end
      when Crystal::InstanceVar
        type_env ||= build_type_env(scope_def, scope_class, cursor)
        if type_ref = type_env.ivars[receiver.name]?
          if owner = resolve_type_ref(type_ref, context)
            return {owner, false}
          end
        end
        if context && (owner = find_class(context))
          return {owner, false}
        end
      when Crystal::ClassVar
        type_env ||= build_type_env(scope_def, scope_class, cursor)
        if type_ref = type_env.cvars[receiver.name]?
          if owner = resolve_type_ref(type_ref, context)
            return {owner, true}
          end
        end
        if context && (owner = find_class(context))
          return {owner, true}
        end
      else
        if receiver
          if type_ref = infer_type_ref(receiver, context, scope_def, scope_class, cursor)
            if owner = resolve_type_ref(type_ref, context)
              return {owner, false}
            end
          end
        elsif context && (owner = find_type(context))
          in_class_method = scope_def && scope_def.receiver
          return {owner, in_class_method ? true : false}
        end
      end
      nil
    end

    private def methods_with_ancestors(
      owner : CRA::Psi::PsiElement,
      class_method : Bool?
    ) : Array(Method)
      results = [] of CRA::Psi::Method
      visited = {} of String => Bool
      collect_methods_with_ancestors(owner, class_method, visited, results)
      results
    end

    private def collect_methods_with_ancestors(
      owner : CRA::Psi::PsiElement,
      class_method : Bool?,
      visited : Hash(String, Bool),
      results : Array(Method)
    )
      return unless owner.is_a?(CRA::Psi::Module) || owner.is_a?(CRA::Psi::Class) || owner.is_a?(CRA::Psi::Enum)

      owner_name = owner.name
      return if visited[owner_name]?
      visited[owner_name] = true

      methods = owner.methods
      if class_method
        methods = methods.select(&.class_method)
      elsif class_method == false
        methods = methods.reject(&.class_method)
      end
      results.concat(methods)

      case owner
      when CRA::Psi::Class
        if class_method != true
          if includes = @class_includes[owner_name]?
            includes.each do |inc|
              if resolved = resolve_type_node(inc, owner_name)
                collect_methods_with_ancestors(resolved, class_method, visited, results)
              end
            end
          end
        end
        if super_node = @class_superclass[owner_name]?
          if resolved = resolve_type_node(super_node, owner_name)
            collect_methods_with_ancestors(resolved, class_method, visited, results)
          end
        end
      when CRA::Psi::Module
        if class_method != true
          if includes = @module_includes[owner_name]?
            includes.each do |inc|
              if resolved = resolve_type_node(inc, owner_name)
                collect_methods_with_ancestors(resolved, class_method, visited, results)
              end
            end
          end
        end
      when CRA::Psi::Enum
      end
    end

    private def method_detail(method : CRA::Psi::Method) : String
      owner_name = method.owner.try(&.name) || "self"
      arity = if max = method.max_arity
                "#{method.min_arity}..#{max}"
              else
                "#{method.min_arity}+"
              end
      "#{owner_name}#{method.class_method ? "." : "#"}#{method.name} (arity #{arity})"
    end

    private def replacement_range(context : CRA::CompletionContext, prefix : String) : CRA::Types::Range
      position = context.request.position
      start_char = position.character - prefix.size
      start_char = 0 if start_char < 0
      CRA::Types::Range.new(
        start_position: CRA::Types::Position.new(line: position.line, character: start_char),
        end_position: CRA::Types::Position.new(line: position.line, character: position.character)
      )
    end

    private def local_definitions(scope_def : Crystal::Def, cursor : Crystal::Location?) : Hash(String, Crystal::ASTNode)
      definitions = {} of String => Crystal::ASTNode
      scope_def.args.each do |arg|
        definitions[arg.name] = arg
      end
      scope_def.body.accept(LocalVarCollector.new(definitions, cursor))
      definitions
    end

    private def resolve_type_name(name : String, context : String?) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      return find_type(name) if name.includes?("::")
      resolve_in_context(name, context)
    end

    private def namespace_completion_data(context : CRA::CompletionContext) : NamedTuple(namespace: String, prefix: String)?
      if match = context.line_prefix.match(/([A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)::([A-Za-z0-9_]*)$/)
        return {namespace: match[1], prefix: match[2]}
      end
      nil
    end

    private def local_definition(scope_def : Crystal::Def, name : String, cursor : Crystal::Location?) : Crystal::ASTNode?
      local_definitions(scope_def, cursor)[name]?
    end

    private def instance_var_definition(
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      name : String,
      cursor : Crystal::Location?
    ) : Crystal::ASTNode?
      if scope_def
        def_finder = InstanceVarDefinitionCollector.new(name, cursor, false)
        scope_def.body.accept(def_finder)
        return def_finder.definition if def_finder.definition
      end

      return nil unless scope_class

      class_finder = InstanceVarDefinitionCollector.new(name, nil, true)
      scope_class.body.accept(class_finder)
      class_finder.definition
    end

    private def resolve_constructor(owner : CRA::Psi::PsiElement, call : Crystal::Call, context : String?) : Array(Method)
      class_methods = find_methods_with_ancestors(owner, "new", true)
      class_matches = filter_methods_by_arity_strict(class_methods, call)
      return class_matches unless class_matches.empty?

      instance_inits = find_methods_with_ancestors(owner, "initialize", false)
      init_matches = filter_methods_by_arity_strict(instance_inits, call)
      return init_matches unless init_matches.empty?

      instance_inits
    end

    private def resolve_type_ref(type_ref : TypeRef, context : String?, depth : Int32 = 0) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      return nil if depth > 6
      if type_ref.union?
        type_ref.union_types.each do |member|
          next if nil_type?(member)
          if resolved = resolve_type_ref(member, context, depth + 1)
            return resolved
          end
        end
        return nil
      end

      name = type_ref.name
      return nil unless name
      return resolve_type_name(context, context) if name == "self" && context

      if resolved = resolve_type_name(name, context)
        return resolved
      end

      if alias_def = resolve_alias_in_context(name, context)
        if target = alias_def.target
          return resolve_type_ref(target, context, depth + 1)
        end
      end

      nil
    end

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
