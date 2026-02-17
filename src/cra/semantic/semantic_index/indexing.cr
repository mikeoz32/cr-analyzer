require "uri"

module CRA::Psi
  class SemanticIndex
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
      name = canonical_name(name)
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
      name = canonical_name(name)
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
      name = canonical_name(name)
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

    # Crystal primitive types have implicit superclass relationships baked into
    # the compiler that don't appear in the source code.  Register them so that
    # ancestor method lookups (e.g., Int64 → Int.from_io) work correctly.
    PRIMITIVE_SUPERCLASSES = {
      "Int8" => "Int", "Int16" => "Int", "Int32" => "Int", "Int64" => "Int", "Int128" => "Int",
      "UInt8" => "Int", "UInt16" => "Int", "UInt32" => "Int", "UInt64" => "Int", "UInt128" => "Int",
      "Float32" => "Float", "Float64" => "Float",
      "Int" => "Number", "Float" => "Number",
      "Number" => "Value", "Value" => "Object",
      "Reference" => "Object",
      "String" => "Reference", "Symbol" => "Value",
      "Bool" => "Value", "Char" => "Value", "Nil" => "Value",
    }

    def register_primitive_superclasses
      PRIMITIVE_SUPERCLASSES.each do |child, parent|
        next if @class_superclass[child]?
        next unless find_class(child) || find_type(child)
        @class_superclass[child] = Crystal::Path.new(parent)
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
      if methods = @methods_by_file.delete(file)
        methods.each { |method| remove_method(method) }
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

    def register_method(method : CRA::Psi::Method)
      key = method_key(method)
      @method_by_key[key] = method
      if file = method.file
        (@methods_by_file[file] ||= [] of CRA::Psi::Method) << method
      end
    end

    def record_call(from_method : CRA::Psi::Method, to_method : CRA::Psi::Method, call_loc : Location?)
      from_key = method_key(from_method)
      to_key = method_key(to_method)
      return if from_key == to_key

      edge = CallEdge.new(to_key, call_loc)
      add_edge(@call_graph, from_key, edge)

      rev_edge = CallEdge.new(from_key, call_loc)
      add_edge(@reverse_call_graph, to_key, rev_edge)
      @method_by_key[from_key] ||= from_method
      @method_by_key[to_key] ||= to_method
    end

    private def record_type_definition(
      name : String,
      kind : Symbol,
      location : Location?,
      element : PsiElement,
      type_vars : Array(String) = [] of String
    )
      name = canonical_name(name)
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
      name = canonical_name(name)
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
      name = canonical_name(name)
      defs = @aliases_by_name[name]?
      return nil unless defs
      return defs[file] if file && defs[file]?
      defs.values.first?
    end

    private def resolve_alias_in_context(name : String, context : String?, file : String? = nil) : CRA::Psi::Alias?
      name = canonical_name(name)
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
      name = canonical_name(name)
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
      name = canonical_name(name)
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
      name = canonical_name(name)
      @roots.each do |root|
        if root.is_a?(CRA::Psi::Enum) && root.name == name
          return root.as(CRA::Psi::Enum)
        end
      end
      nil
    end

    private def find_type(name : String) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      name = canonical_name(name)
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

    def method_for_call_item(item : CRA::Types::CallHierarchyItem) : CRA::Psi::Method?
      files = [item.uri]
      begin
        files << URI.parse(item.uri).path
      rescue
      end
      files.each do |file|
        next unless methods = @methods_by_file[file]?
        methods.each do |method|
          if method.name == item.name && location_matches_range?(method.location, item.range)
            return method
          end
        end
      end
      nil
    end

    def call_hierarchy_outgoing_methods(item : CRA::Types::CallHierarchyItem) : Array(NamedTuple(method: CRA::Psi::Method, ranges: Array(CRA::Types::Range)))
      method = method_for_call_item(item)
      return [] of NamedTuple(method: CRA::Psi::Method, ranges: Array(CRA::Types::Range)) unless method
      key = method_key(method)
      targets = @call_graph[key]?
      return [] of NamedTuple(method: CRA::Psi::Method, ranges: Array(CRA::Types::Range)) unless targets
      results = [] of NamedTuple(method: CRA::Psi::Method, ranges: Array(CRA::Types::Range))
      targets.each do |edge|
        next unless target = @method_by_key[edge.target_key]?
        ranges = [] of CRA::Types::Range
        if loc = edge.location
          ranges << loc.to_range
        end
        results << {method: target, ranges: ranges}
      end
      results
    end

    def call_hierarchy_incoming_methods(item : CRA::Types::CallHierarchyItem) : Array(NamedTuple(method: CRA::Psi::Method, ranges: Array(CRA::Types::Range)))
      method = method_for_call_item(item)
      return [] of NamedTuple(method: CRA::Psi::Method, ranges: Array(CRA::Types::Range)) unless method
      key = method_key(method)
      callers = @reverse_call_graph[key]?
      return [] of NamedTuple(method: CRA::Psi::Method, ranges: Array(CRA::Types::Range)) unless callers
      results = [] of NamedTuple(method: CRA::Psi::Method, ranges: Array(CRA::Types::Range))
      callers.each do |edge|
        next unless caller = @method_by_key[edge.target_key]?
        ranges = [] of CRA::Types::Range
        if loc = edge.location
          ranges << loc.to_range
        end
        results << {method: caller, ranges: ranges}
      end
      results
    end

    def type_hierarchy_supertypes(name : String) : Array(PsiElement)
      name = canonical_name(name)
      element = find_type(name)
      return [] of PsiElement unless element

      results = [] of PsiElement
      case element
      when CRA::Psi::Class
        if super_node = @class_superclass[element.name]?
          if resolved = resolve_type_node(super_node, element.name)
            if super_elem = find_type(resolved.name)
              results << super_elem
            else
              results.concat(type_definition_elements(resolved.name))
            end
          end
        else
          if default_super = find_type("Reference") || find_type("Object")
            results << default_super
          end
        end

        if includes = @class_includes[element.name]?
          includes.each do |inc|
            if resolved = resolve_type_node(inc, element.name)
              if inc_elem = find_type(resolved.name)
                results << inc_elem
              end
            end
          end
        end
      when CRA::Psi::Module
        if includes = @module_includes[element.name]?
          includes.each do |inc|
            if resolved = resolve_type_node(inc, element.name)
              if inc_elem = find_type(resolved.name)
                results << inc_elem
              end
            end
          end
        end
      end

      dedupe_types(results)
    end

    def type_hierarchy_subtypes(name : String) : Array(PsiElement)
      name = canonical_name(name)
      element = find_type(name)
      return [] of PsiElement unless element

      results = [] of PsiElement
      if element.is_a?(CRA::Psi::Class)
        results.concat(subclasses_for(element.name))
      elsif element.is_a?(CRA::Psi::Module)
        results.concat(includers_for(element.name))
      end
      dedupe_types(results)
    end

    private def dedupe_types(types : Array(PsiElement)) : Array(PsiElement)
      seen = {} of String => Bool
      types.select do |t|
        next false unless name = t.try(&.name)
        unless seen[name]?
          seen[name] = true
          true
        else
          false
        end
      end
    end

    private def canonical_name(name : String) : String
      name.starts_with?("::") ? name[2..] : name
    end

    private def method_key(method : CRA::Psi::Method) : String
      owner_name = method.owner.try(&.name) || ""
      separator = method.class_method ? "." : "#"
      "#{owner_name}#{separator}#{method.name}"
    end

    # Returns direct ancestor methods for a given method (superclasses/included modules).
    def super_methods_for(method : CRA::Psi::Method) : Array(CRA::Psi::Method)
      owner = method.owner
      return [] of CRA::Psi::Method unless owner
      return [] of CRA::Psi::Method unless type = find_type(owner.name)
      results = find_methods_with_ancestors(type, method.name, method.class_method)
      results.reject! { |m| m.location == method.location }
      results
    end

    private def remove_method(method : CRA::Psi::Method)
      key = method_key(method)
      @method_by_key.delete(key)
      @call_graph.delete(key)
      @reverse_call_graph.delete(key)
      @call_graph.each do |from, edges|
        edges.reject! { |edge| edge.target_key == key }
        @call_graph.delete(from) if edges.empty?
      end
      @reverse_call_graph.each do |to, edges|
        edges.reject! { |edge| edge.target_key == key }
        @reverse_call_graph.delete(to) if edges.empty?
      end
    end

    private def add_edge(store : Hash(String, Array(CallEdge)), key : String, edge : CallEdge)
      edges = (store[key] ||= [] of CallEdge)
      edges << edge unless edges.any? { |existing| existing.target_key == edge.target_key && existing.location == edge.location }
    end

    private def location_matches_range?(location : CRA::Psi::Location?, range : CRA::Types::Range) : Bool
      return false unless location
      location.start_line == range.start_position.line &&
        location.start_character == range.start_position.character &&
        location.end_line == range.end_position.line &&
        location.end_character == range.end_position.character
    end
  end
end
