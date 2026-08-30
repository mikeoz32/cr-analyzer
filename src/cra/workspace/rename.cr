require "../types"
require "compiler/crystal/syntax"
require "./visitor_helpers"

module CRA
  class Workspace
    def prepare_rename(request : Types::PrepareRenameRequest) : Types::Range?
      document = document(request.text_document.uri)
      return nil unless document

      if facet_finder = document.facet_node_context(request.position)
        if facet_node = facet_finder.semantic_node
          if facet_renameable?(facet_node)
            if span = facet_finder.semantic_name_span
              return facet_range(facet_finder.tree, span)
            end
          end
        end
      end

      finder = document.node_context(request.position)
      node = finder.node || finder.previous_node
      return nil unless node

      cursor = finder.cursor_location
      case node
      when Crystal::Var
        return nil if node.name.starts_with?("$")
        node_name_range(node)
      when Crystal::Arg
        node_name_range(node)
      when Crystal::InstanceVar, Crystal::ClassVar, Crystal::Call, Crystal::Def
        node_name_range(node)
      when Crystal::Path
        segment_index = path_segment_index(node, cursor)
        path_segment_range(node, segment_index)
      when Crystal::ClassDef
        segment_index = path_segment_index(node.name, cursor)
        path_segment_range(node.name, segment_index)
      when Crystal::ModuleDef
        segment_index = path_segment_index(node.name, cursor)
        path_segment_range(node.name, segment_index)
      when Crystal::EnumDef
        segment_index = path_segment_index(node.name, cursor)
        path_segment_range(node.name, segment_index)
      when Crystal::Alias
        segment_index = path_segment_index(node.name, cursor)
        path_segment_range(node.name, segment_index)
      else
        nil
      end
    end

    def rename(request : Types::RenameRequest) : Types::WorkspaceEdit?
      new_name = request.new_name
      return nil if new_name.empty?

      document = document(request.text_document.uri)
      return nil unless document

      if edit = rename_with_facet(document, request.position, request.text_document.uri, new_name)
        return edit
      end

      finder = document.node_context(request.position)
      node = finder.node || finder.previous_node
      return nil unless node

      changes = {} of String => Types::TextEdits

      case node
      when Crystal::Var
        rename_local_var(node, new_name, finder, request.text_document.uri, changes)
      when Crystal::Arg
        if enum_name = enum_name_for_arg(node, finder)
          rename_enum_member(enum_name, node.name, new_name, changes)
        else
          rename_local_arg(node, new_name, finder, request.text_document.uri, changes)
        end
      when Crystal::InstanceVar
        rename_instance_var(node, new_name, finder, request.text_document.uri, changes)
      when Crystal::ClassVar
        rename_class_var(node, new_name, finder, request.text_document.uri, changes)
      when Crystal::Call, Crystal::Def
        rename_method(node, new_name, finder, request.text_document.uri, changes)
      when Crystal::Path
        rename_type_path(node, new_name, finder, request.text_document.uri, changes)
      when Crystal::ClassDef
        rename_type_definition(node.name, new_name, finder, request.text_document.uri, changes)
      when Crystal::ModuleDef
        rename_type_definition(node.name, new_name, finder, request.text_document.uri, changes)
      when Crystal::EnumDef
        rename_type_definition(node.name, new_name, finder, request.text_document.uri, changes)
      when Crystal::Alias
        rename_type_definition(node.name, new_name, finder, request.text_document.uri, changes)
      else
        return nil
      end

      return nil if changes.empty?
      Types::WorkspaceEdit.new(changes: changes)
    end

    private def rename_with_facet(
      document : WorkspaceDocument,
      position : Types::Position,
      uri : String,
      new_name : String,
    ) : Types::WorkspaceEdit?
      finder = document.facet_node_context(position)
      return nil unless finder
      node = finder.semantic_node
      return nil unless node && facet_renameable?(node)
      name = facet_symbol_name(node)
      return nil unless name && !name.empty? && name != new_name

      occurrences = case node.kind
                    when Facet::Compiler::NodeKind::Param, Facet::Compiler::NodeKind::Splat,
                         Facet::Compiler::NodeKind::DoubleSplat, Facet::Compiler::NodeKind::BlockParam
                      if name.starts_with?("@@")
                        type_name = finder.enclosing_type_name
                        type_name ? facet_scoped_variable_occurrences(type_name, name, Facet::Compiler::NodeKind::ClassVar) : [] of FacetOccurrence
                      elsif name.starts_with?("@")
                        type_name = finder.enclosing_type_name
                        type_name ? facet_scoped_variable_occurrences(type_name, name, Facet::Compiler::NodeKind::InstanceVar) : [] of FacetOccurrence
                      else
                        facet_local_occurrences(finder, name, uri)
                      end
                    when Facet::Compiler::NodeKind::InstanceVar
                      type_name = finder.enclosing_type_name
                      type_name ? facet_scoped_variable_occurrences(type_name, name, node.kind) : [] of FacetOccurrence
                    when Facet::Compiler::NodeKind::ClassVar
                      type_name = finder.enclosing_type_name
                      type_name ? facet_scoped_variable_occurrences(type_name, name, node.kind) : [] of FacetOccurrence
                    when Facet::Compiler::NodeKind::Call, Facet::Compiler::NodeKind::CallWithBlock,
                         Facet::Compiler::NodeKind::Binary, Facet::Compiler::NodeKind::Def,
                         Facet::Compiler::NodeKind::Fun
                      definitions = @facet_analyzer.find_facet_definitions(
                        node, finder.context_path, finder.byte_offset, finder.enclosing_type_name, uri
                      )
                      keys = method_keys_for(definitions)
                      keys.empty? ? [] of FacetOccurrence : facet_method_occurrences(keys)
                    when Facet::Compiler::NodeKind::Ident
                      if !name[0].ascii_uppercase?
                        definitions = @facet_analyzer.find_facet_definitions(
                          node, finder.context_path, finder.byte_offset, finder.enclosing_type_name, uri
                        )
                        keys = method_keys_for(definitions)
                        keys.empty? ? facet_local_occurrences(finder, name, uri) : facet_method_occurrences(keys)
                      else
                        facet_type_rename_occurrences(node, finder, uri)
                      end
                    else
                      facet_type_rename_occurrences(node, finder, uri)
                    end
      return nil if occurrences.empty?

      replacement = case node.kind
                    when Facet::Compiler::NodeKind::InstanceVar
                      normalize_instance_var_name(new_name)
                    when Facet::Compiler::NodeKind::ClassVar
                      normalize_class_var_name(new_name)
                    when Facet::Compiler::NodeKind::Param
                      if name.starts_with?("@@")
                        normalize_class_var_name(new_name)
                      elsif name.starts_with?("@")
                        normalize_instance_var_name(new_name)
                      else
                        new_name
                      end
                    else
                      new_name
                    end

      changes = {} of String => Types::TextEdits
      occurrences.each do |occurrence|
        append_edits(changes, occurrence.uri, [Types::TextEdit.new(occurrence.range, replacement)] of Types::TextEdit | Types::AnnotatedTextEdit | Types::SnippetTextEdit)
      end
      changes.empty? ? nil : Types::WorkspaceEdit.new(changes: changes)
    rescue ex
      Log.error { "Facet rename failed: #{ex.message}" }
      nil
    end

    private def facet_type_rename_occurrences(
      node : Facet::Compiler::SyntaxNode,
      finder : FacetNodeFinder,
      uri : String,
    ) : Array(FacetOccurrence)
      definitions = @facet_analyzer.find_facet_definitions(
        node, finder.context_path, finder.byte_offset, finder.enclosing_type_name, uri
      )
      keys = type_keys_for(definitions)
      keys.empty? ? [] of FacetOccurrence : facet_type_occurrences(keys)
    end

    private def facet_renameable?(node : Facet::Compiler::SyntaxNode) : Bool
      return false if node.kind == Facet::Compiler::NodeKind::Global
      return false unless facet_symbol_name(node)
      {
        Facet::Compiler::NodeKind::Ident,
        Facet::Compiler::NodeKind::Const,
        Facet::Compiler::NodeKind::Path,
        Facet::Compiler::NodeKind::TypeApply,
        Facet::Compiler::NodeKind::InstanceVar,
        Facet::Compiler::NodeKind::ClassVar,
        Facet::Compiler::NodeKind::Param,
        Facet::Compiler::NodeKind::Splat,
        Facet::Compiler::NodeKind::DoubleSplat,
        Facet::Compiler::NodeKind::BlockParam,
        Facet::Compiler::NodeKind::Call,
        Facet::Compiler::NodeKind::CallWithBlock,
        Facet::Compiler::NodeKind::Binary,
        Facet::Compiler::NodeKind::Def,
        Facet::Compiler::NodeKind::Fun,
        Facet::Compiler::NodeKind::Class,
        Facet::Compiler::NodeKind::Module,
        Facet::Compiler::NodeKind::Struct,
        Facet::Compiler::NodeKind::Enum,
        Facet::Compiler::NodeKind::Alias,
        Facet::Compiler::NodeKind::TypeDef,
      }.includes?(node.kind)
    end

    private def facet_symbol_name(node : Facet::Compiler::SyntaxNode) : String?
      if node.call_name
        node.call_name
      elsif {Facet::Compiler::NodeKind::Def, Facet::Compiler::NodeKind::Fun}.includes?(node.kind)
        facet_terminal_name(node.name_node).try(&.symbol_name) || node.name
      else
        node.symbol_name || node.name
      end
    end

    private def rename_local_var(
      node : Crystal::Var,
      new_name : String,
      finder : NodeFinder,
      uri : String,
      changes : Hash(String, Types::TextEdits),
    )
      if block = block_for_var(node, finder.context_path)
        edits = rename_block_local(block, node.name, new_name)
        append_edits(changes, uri, edits)
        return
      end
      edits = rename_def_local(finder.enclosing_def, node.name, new_name)
      append_edits(changes, uri, edits)
    end

    private def rename_local_arg(
      node : Crystal::Arg,
      new_name : String,
      finder : NodeFinder,
      uri : String,
      changes : Hash(String, Types::TextEdits),
    )
      edits = rename_def_local(finder.enclosing_def, node.name, new_name)
      append_edits(changes, uri, edits)
    end

    private def rename_instance_var(
      node : Crystal::InstanceVar,
      new_name : String,
      finder : NodeFinder,
      uri : String,
      changes : Hash(String, Types::TextEdits),
    )
      class_name = finder.enclosing_type_name
      return unless class_name

      target_name = normalize_instance_var_name(new_name)
      edits_by_uri = rename_class_scoped_var(class_name, node.name, target_name, :instance)
      merge_changes(changes, edits_by_uri)
    end

    private def rename_class_var(
      node : Crystal::ClassVar,
      new_name : String,
      finder : NodeFinder,
      uri : String,
      changes : Hash(String, Types::TextEdits),
    )
      class_name = finder.enclosing_type_name
      return unless class_name

      target_name = normalize_class_var_name(new_name)
      edits_by_uri = rename_class_scoped_var(class_name, node.name, target_name, :class)
      merge_changes(changes, edits_by_uri)
    end

    private def rename_method(
      node : Crystal::ASTNode,
      new_name : String,
      finder : NodeFinder,
      uri : String,
      changes : Hash(String, Types::TextEdits),
    )
      definitions = @analyzer.find_definitions(
        node,
        finder.enclosing_type_name,
        finder.enclosing_def,
        finder.enclosing_class,
        finder.cursor_location,
        uri
      )
      target_keys = method_keys_for(definitions)
      return if target_keys.empty?

      edits_by_uri = rename_methods_in_workspace(target_keys, new_name)
      merge_changes(changes, edits_by_uri)
    end

    private def rename_type_path(
      node : Crystal::Path,
      new_name : String,
      finder : NodeFinder,
      uri : String,
      changes : Hash(String, Types::TextEdits),
    )
      definitions = @analyzer.find_definitions(
        node,
        finder.enclosing_type_name,
        finder.enclosing_def,
        finder.enclosing_class,
        finder.cursor_location,
        uri
      )
      target_keys = type_keys_for(definitions)
      return if target_keys.empty?

      segment_index = path_segment_index(node, finder.cursor_location)
      edits_by_uri = rename_types_in_workspace(target_keys, new_name, segment_index)
      merge_changes(changes, edits_by_uri)
    end

    private def rename_type_definition(
      node : Crystal::Path,
      new_name : String,
      finder : NodeFinder,
      uri : String,
      changes : Hash(String, Types::TextEdits),
    )
      full_name = qualified_name(node.full, finder.context_path)
      return if full_name.empty?

      target_keys = {"type:#{full_name}" => true}
      segment_index = path_segment_index(node, finder.cursor_location)
      edits_by_uri = rename_types_in_workspace(target_keys, new_name, segment_index)
      merge_changes(changes, edits_by_uri)
    end

    private def rename_enum_member(
      enum_name : String,
      member_name : String,
      new_name : String,
      changes : Hash(String, Types::TextEdits),
    )
      target_keys = {"enum_member:#{enum_name}::#{member_name}" => true}
      edits_by_uri = rename_types_in_workspace(target_keys, new_name, -1)
      merge_changes(changes, edits_by_uri)
    end

    private def rename_def_local(scope_def : Crystal::Def?, name : String, new_name : String) : Types::TextEdits
      return [] of Types::TextEdit | Types::AnnotatedTextEdit | Types::SnippetTextEdit unless scope_def
      return [] of Types::TextEdit | Types::AnnotatedTextEdit | Types::SnippetTextEdit if name == new_name

      nodes = [] of Crystal::ASTNode
      scope_def.args.each do |arg|
        nodes << arg if arg.name == name
      end

      collector = ScopedLocalRenameCollector.new(name)
      scope_def.body.accept(collector)
      nodes.concat(collector.nodes)
      edits_for_nodes(nodes, new_name)
    end

    private def rename_block_local(block : Crystal::Block, name : String, new_name : String) : Types::TextEdits
      return [] of Types::TextEdit | Types::AnnotatedTextEdit | Types::SnippetTextEdit if name == new_name

      nodes = [] of Crystal::ASTNode
      block.args.each do |arg|
        nodes << arg if arg.name == name
      end

      collector = ScopedLocalRenameCollector.new(name)
      block.body.accept(collector)
      nodes.concat(collector.nodes)
      edits_for_nodes(nodes, new_name)
    end

    private def rename_class_scoped_var(
      class_name : String,
      name : String,
      new_name : String,
      kind : Symbol,
    ) : Hash(String, Types::TextEdits)
      return {} of String => Types::TextEdits if name == new_name

      edits_by_uri = {} of String => Types::TextEdits
      workspace_file_uris.each do |file_uri|
        program = program_for_uri(file_uri)
        next unless program

        collector = ClassScopedVarRenameCollector.new(class_name, name, kind)
        program.accept(collector)
        edits = edits_for_nodes(collector.nodes, new_name)
        append_edits(edits_by_uri, file_uri, edits)
      end
      edits_by_uri
    end

    private def rename_methods_in_workspace(
      target_keys : Hash(String, Bool),
      new_name : String,
    ) : Hash(String, Types::TextEdits)
      edits_by_uri = {} of String => Types::TextEdits
      workspace_file_uris.each do |file_uri|
        program = program_for_uri(file_uri)
        next unless program

        collector = MethodRenameCollector.new(@analyzer, file_uri, target_keys)
        program.accept(collector)

        edits = [] of Types::TextEdit | Types::AnnotatedTextEdit | Types::SnippetTextEdit
        collector.def_nodes.each do |def_node|
          next if def_node.name == new_name
          if range = def_name_range(def_node)
            edits << Types::TextEdit.new(range, new_name)
          end
        end
        collector.call_nodes.each do |call_node|
          next if call_node.name == new_name
          if range = call_name_range(call_node)
            edits << Types::TextEdit.new(range, new_name)
          end
        end
        append_edits(edits_by_uri, file_uri, edits)
      end
      edits_by_uri
    end

    private def rename_types_in_workspace(
      target_keys : Hash(String, Bool),
      new_name : String,
      segment_index : Int32,
    ) : Hash(String, Types::TextEdits)
      type_targets = {} of String => Bool
      enum_member_targets = {} of String => Bool
      target_keys.each do |key, _|
        if key.starts_with?("type:")
          type_targets[key] = true
        elsif key.starts_with?("enum_member:")
          enum_member_targets[key] = true
        end
      end

      edits_by_uri = {} of String => Types::TextEdits
      workspace_file_uris.each do |file_uri|
        program = program_for_uri(file_uri)
        next unless program

        edits = [] of Types::TextEdit | Types::AnnotatedTextEdit | Types::SnippetTextEdit

        if !type_targets.empty?
          type_collector = TypeDefinitionRenameCollector.new(type_targets)
          program.accept(type_collector)
          type_collector.paths.each do |path_node|
            range = path_segment_range(path_node, segment_index)
            next unless range
            edits << Types::TextEdit.new(range, new_name)
          end
        end

        if !enum_member_targets.empty?
          member_collector = EnumMemberRenameCollector.new(enum_member_targets)
          program.accept(member_collector)
          member_collector.members.each do |member_node|
            range = node_name_range(member_node)
            next unless range
            edits << Types::TextEdit.new(range, new_name)
          end
        end

        path_collector = PathRenameCollector.new(@analyzer, file_uri, target_keys)
        program.accept(path_collector)
        path_collector.path_nodes.each do |path_node|
          range = path_segment_range(path_node, segment_index)
          next unless range
          edits << Types::TextEdit.new(range, new_name)
        end

        append_edits(edits_by_uri, file_uri, edits)
      end
      edits_by_uri
    end

    private def edits_for_nodes(nodes : Array(Crystal::ASTNode), new_name : String) : Types::TextEdits
      edits = [] of Types::TextEdit | Types::AnnotatedTextEdit | Types::SnippetTextEdit
      nodes.each do |node|
        range = node_name_range(node)
        next unless range
        edits << Types::TextEdit.new(range, new_name)
      end
      dedupe_edits(edits)
    end

    private def append_edits(changes : Hash(String, Types::TextEdits), uri : String, edits : Types::TextEdits)
      return if edits.empty?
      if existing = changes[uri]?
        existing.concat(edits)
        changes[uri] = dedupe_edits(existing)
      else
        changes[uri] = dedupe_edits(edits)
      end
    end

    private def merge_changes(target : Hash(String, Types::TextEdits), source : Hash(String, Types::TextEdits))
      source.each do |uri, edits|
        append_edits(target, uri, edits)
      end
    end

    private def dedupe_edits(edits : Types::TextEdits) : Types::TextEdits
      seen = {} of String => Bool
      unique = [] of Types::TextEdit | Types::AnnotatedTextEdit | Types::SnippetTextEdit
      edits.each do |edit|
        key = "#{edit.range.start_position.line}:#{edit.range.start_position.character}:" \
              "#{edit.range.end_position.line}:#{edit.range.end_position.character}"
        next if seen[key]?
        seen[key] = true
        unique << edit
      end
      unique
    end

    private def block_for_var(node : Crystal::Var, path : Array(Crystal::ASTNode)) : Crystal::Block?
      path.reverse_each do |entry|
        next unless entry.is_a?(Crystal::Block)
        return entry if entry.args.any? { |arg| arg.same?(node) }
      end
      nil
    end

    private def normalize_instance_var_name(name : String) : String
      return name if name.starts_with?("@")
      "@#{name}"
    end

    private def normalize_class_var_name(name : String) : String
      return name if name.starts_with?("@@")
      return "@@#{name[1..]}" if name.starts_with?("@")
      "@@#{name}"
    end

    private def method_keys_for(definitions : Array(Psi::PsiElement)) : Hash(String, Bool)
      keys = {} of String => Bool
      definitions.each do |definition|
        method = definition.as?(Psi::Method)
        next unless method
        owner_name = method.owner.try(&.name)
        next unless owner_name
        keys[method_key(owner_name, method.class_method, method.name)] = true
      end
      keys
    end

    private def type_keys_for(definitions : Array(Psi::PsiElement)) : Hash(String, Bool)
      keys = {} of String => Bool
      definitions.each do |definition|
        if key = type_key(definition)
          keys[key] = true
        end
      end
      keys
    end

    private def method_key(owner_name : String, class_method : Bool, name : String) : String
      "method:#{owner_name}:#{class_method ? "class" : "instance"}:#{name}"
    end

    private def type_key(definition : Psi::PsiElement) : String?
      case definition
      when Psi::Class, Psi::Module, Psi::Enum, Psi::Alias
        "type:#{definition.name}"
      when Psi::EnumMember
        "enum_member:#{definition.owner.name}::#{definition.name}"
      else
        nil
      end
    end

    private def workspace_file_uris : Array(String)
      files = [] of String
      Dir.glob(@path.join("**/*.cr").to_s) do |file_path|
        files << "file://#{file_path}"
      end
      files
    end

    private def program_for_uri(uri : String) : Crystal::ASTNode?
      if document = @documents[uri]?
        return document.program
      end
      path = URI.parse(uri).path
      return nil unless File.exists?(path)
      parser = Crystal::Parser.new(File.read(path))
      parser.wants_doc = true
      parser.parse
    rescue ex : Exception
      Log.error { "Error parsing #{uri}: #{ex.message}" }
      nil
    end

    private def call_name_range(call : Crystal::Call) : Types::Range?
      loc = call.name_location || call.location
      return nil unless loc
      range_from_location_and_size(loc, call.name_size)
    end

    private def def_name_range(def_node : Crystal::Def) : Types::Range?
      loc = def_node.name_location || def_node.location
      return nil unless loc
      range_from_location_and_size(loc, def_node.name_size)
    end

    private def path_segment_index(path : Crystal::Path, cursor : Crystal::Location?) : Int32
      return path.names.size - 1 unless cursor
      loc = path.location
      return path.names.size - 1 unless loc

      start_char = loc.column_number - 1
      cursor_char = cursor.column_number - 1
      offset = path.global? ? 2 : 0

      path.names.each_with_index do |name, idx|
        seg_start = start_char + offset
        seg_end = seg_start + name.size
        return idx if cursor_char >= seg_start && cursor_char < seg_end
        offset += name.size + 2
      end

      path.names.size - 1
    end

    private def path_segment_range(path : Crystal::Path, index : Int32) : Types::Range?
      loc = path.location
      return nil unless loc
      return nil if path.names.empty?

      idx = index
      idx = path.names.size - 1 if idx < 0 || idx >= path.names.size

      start_char = loc.column_number - 1
      offset = path.global? ? 2 : 0
      path.names.each_with_index do |name, current_idx|
        seg_start = start_char + offset
        seg_end = seg_start + name.size
        if current_idx == idx
          return Types::Range.new(
            start_position: Types::Position.new(line: loc.line_number - 1, character: seg_start),
            end_position: Types::Position.new(line: loc.line_number - 1, character: seg_end)
          )
        end
        offset += name.size + 2
      end
      nil
    end

    private def enum_name_for_arg(node : Crystal::Arg, finder : NodeFinder) : String?
      enum_node = finder.context_path.reverse.find(&.is_a?(Crystal::EnumDef))
      return nil unless enum_node
      enum_def = enum_node.as(Crystal::EnumDef)
      return nil unless enum_def.members.any? { |member| member.same?(node) }
      finder.enclosing_type_name
    end

    private def qualified_name(name : String, path : Array(Crystal::ASTNode)) : String
      return name if name.includes?("::")
      names = [] of String
      path.each do |node|
        type_name = case node
                    when Crystal::ClassDef
                      node.name.full
                    when Crystal::ModuleDef
                      node.name.full
                    when Crystal::EnumDef
                      node.name.full
                    else
                      nil
                    end
        next unless type_name
        if type_name.includes?("::")
          names = [type_name]
        else
          names << type_name
        end
      end
      return name if names.empty?
      (names + [name]).join("::")
    end
  end

  class ScopedLocalRenameCollector < Crystal::Visitor
    include Workspace::VisitorHelpers

    getter nodes : Array(Crystal::ASTNode)

    def initialize(@name : String)
      @nodes = [] of Crystal::ASTNode
    end

    continue_all
    stop_at Crystal::Def, Crystal::ClassDef, Crystal::ModuleDef, Crystal::EnumDef, Crystal::Macro

    def visit(node : Crystal::Var) : Bool
      @nodes << node if node.name == @name
      true
    end

    def visit(node : Crystal::Block) : Bool
      return false if node.args.any? { |arg| arg.name == @name }
      true
    end
  end

  class ClassScopedVarRenameCollector < Crystal::Visitor
    include Workspace::VisitorHelpers

    getter nodes : Array(Crystal::ASTNode)
    @current_namespace : String?

    def initialize(@class_name : String, @var_name : String, @kind : Symbol)
      @nodes = [] of Crystal::ASTNode
      @current_namespace = nil
    end

    continue_all
    stop_at_macros

    def visit(node : Crystal::ModuleDef) : Bool
      with_namespace(node.name.full) do
        node.body.accept(self)
      end
      false
    end

    def visit(node : Crystal::EnumDef) : Bool
      with_namespace(node.name.full) do
        node.accept_children(self)
      end
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      with_namespace(node.name.full) do
        if @current_namespace == @class_name
          if @kind == :class
            class_collector = NameHighlightCollector.new(@var_name, cvar: true)
            node.body.accept(class_collector)
            @nodes.concat(class_collector.nodes)
          else
            instance_collector = NameHighlightCollector.new(@var_name, ivar: true)
            node.body.accept(instance_collector)
            @nodes.concat(instance_collector.nodes)
          end
        end
        node.body.accept(self)
      end
      false
    end

    private def with_namespace(name : String, &)
      prev = @current_namespace
      @current_namespace = qualify_name(name, prev)
      yield
      @current_namespace = prev
    end

    private def qualify_name(name : String, namespace : String?) : String
      return name if name.includes?("::")
      return name unless namespace
      "#{namespace}::#{name}"
    end
  end

  class MethodRenameCollector < Crystal::Visitor
    include Workspace::VisitorHelpers

    getter call_nodes : Array(Crystal::Call)
    getter def_nodes : Array(Crystal::Def)
    @current_type : String?
    @current_class : Crystal::ClassDef?
    @current_def : Crystal::Def?

    def initialize(@index : CRA::Psi::SemanticIndex, @file_uri : String, @target_keys : Hash(String, Bool))
      @call_nodes = [] of Crystal::Call
      @def_nodes = [] of Crystal::Def
      @current_type = nil
      @current_class = nil
      @current_def = nil
    end

    stop_at_macros

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::ModuleDef) : Bool
      prev_class = @current_class
      with_type(node.name.full) do
        @current_class = nil
        node.body.accept(self)
        @current_class = prev_class
      end
      false
    end

    def visit(node : Crystal::EnumDef) : Bool
      prev_class = @current_class
      with_type(node.name.full) do
        @current_class = nil
        node.accept_children(self)
        @current_class = prev_class
      end
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      prev_class = @current_class
      with_type(node.name.full) do
        @current_class = node
        node.body.accept(self)
        @current_class = prev_class
      end
      false
    end

    def visit(node : Crystal::Def) : Bool
      prev_def = @current_def
      @current_def = node
      if def_matches?(node)
        @def_nodes << node
      end
      node.body.accept(self)
      @current_def = prev_def
      false
    end

    def visit(node : Crystal::Call) : Bool
      definitions = @index.find_definitions(
        node,
        @current_type,
        @current_def,
        @current_class,
        node.location,
        @file_uri
      )
      definitions.each do |definition|
        method = definition.as?(CRA::Psi::Method)
        next unless method
        owner_name = method.owner.try(&.name)
        next unless owner_name
        key = "method:#{owner_name}:#{method.class_method ? "class" : "instance"}:#{method.name}"
        if @target_keys[key]?
          @call_nodes << node
          break
        end
      end
      true
    end

    private def def_matches?(node : Crystal::Def) : Bool
      return false unless @current_type
      key = "method:#{@current_type}:#{node.receiver ? "class" : "instance"}:#{node.name}"
      @target_keys.has_key?(key)
    end

    private def with_type(name : String, &)
      prev = @current_type
      @current_type = qualify_name(name, prev)
      yield
      @current_type = prev
    end

    private def qualify_name(name : String, namespace : String?) : String
      return name if name.includes?("::")
      return name unless namespace
      "#{namespace}::#{name}"
    end
  end

  class PathRenameCollector < Crystal::Visitor
    include Workspace::VisitorHelpers

    getter path_nodes : Array(Crystal::Path)
    @current_type : String?
    @current_class : Crystal::ClassDef?
    @current_def : Crystal::Def?

    def initialize(@index : CRA::Psi::SemanticIndex, @file_uri : String, @target_keys : Hash(String, Bool))
      @path_nodes = [] of Crystal::Path
      @current_type = nil
      @current_class = nil
      @current_def = nil
    end

    stop_at_macros

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::ModuleDef) : Bool
      prev_class = @current_class
      with_type(node.name.full) do
        @current_class = nil
        node.body.accept(self)
        @current_class = prev_class
      end
      false
    end

    def visit(node : Crystal::EnumDef) : Bool
      prev_class = @current_class
      with_type(node.name.full) do
        @current_class = nil
        node.accept_children(self)
        @current_class = prev_class
      end
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      prev_class = @current_class
      with_type(node.name.full) do
        @current_class = node
        node.body.accept(self)
        @current_class = prev_class
      end
      false
    end

    def visit(node : Crystal::Def) : Bool
      prev_def = @current_def
      @current_def = node
      node.body.accept(self)
      @current_def = prev_def
      false
    end

    def visit(node : Crystal::Path) : Bool
      definitions = @index.find_definitions(
        node,
        @current_type,
        @current_def,
        @current_class,
        node.location,
        @file_uri
      )
      definitions.each do |definition|
        key = case definition
              when CRA::Psi::Class, CRA::Psi::Module, CRA::Psi::Enum, CRA::Psi::Alias
                "type:#{definition.name}"
              when CRA::Psi::EnumMember
                "enum_member:#{definition.owner.name}::#{definition.name}"
              else
                nil
              end
        if key && @target_keys[key]?
          @path_nodes << node
          break
        end
      end
      true
    end

    private def with_type(name : String, &)
      prev = @current_type
      @current_type = qualify_name(name, prev)
      yield
      @current_type = prev
    end

    private def qualify_name(name : String, namespace : String?) : String
      return name if name.includes?("::")
      return name unless namespace
      "#{namespace}::#{name}"
    end
  end

  class TypeDefinitionRenameCollector < Crystal::Visitor
    include Workspace::VisitorHelpers

    getter paths : Array(Crystal::Path)
    @current_namespace : String?

    def initialize(@target_keys : Hash(String, Bool))
      @paths = [] of Crystal::Path
      @current_namespace = nil
    end

    continue_all
    stop_at_macros

    def visit(node : Crystal::ModuleDef) : Bool
      full_name = qualify_name(node.name.full, @current_namespace)
      if @target_keys["type:#{full_name}"]?
        @paths << node.name
      end
      with_namespace(full_name) do
        node.body.accept(self)
      end
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      full_name = qualify_name(node.name.full, @current_namespace)
      if @target_keys["type:#{full_name}"]?
        @paths << node.name
      end
      with_namespace(full_name) do
        node.body.accept(self)
      end
      false
    end

    def visit(node : Crystal::EnumDef) : Bool
      full_name = qualify_name(node.name.full, @current_namespace)
      if @target_keys["type:#{full_name}"]?
        @paths << node.name
      end
      with_namespace(full_name) do
        node.accept_children(self)
      end
      false
    end

    def visit(node : Crystal::Alias) : Bool
      full_name = qualify_name(node.name.full, @current_namespace)
      if @target_keys["type:#{full_name}"]?
        @paths << node.name
      end
      false
    end

    private def with_namespace(name : String, &)
      prev = @current_namespace
      @current_namespace = name
      yield
      @current_namespace = prev
    end

    private def qualify_name(name : String, namespace : String?) : String
      return name if name.includes?("::")
      return name unless namespace
      "#{namespace}::#{name}"
    end
  end

  class EnumMemberRenameCollector < Crystal::Visitor
    include Workspace::VisitorHelpers

    getter members : Array(Crystal::ASTNode)
    @current_namespace : String?

    def initialize(@target_keys : Hash(String, Bool))
      @members = [] of Crystal::ASTNode
      @current_namespace = nil
    end

    continue_all
    stop_at_macros

    def visit(node : Crystal::EnumDef) : Bool
      full_name = qualify_name(node.name.full, @current_namespace)
      node.members.each do |member|
        next unless member.is_a?(Crystal::Arg)
        key = "enum_member:#{full_name}::#{member.name}"
        if @target_keys[key]?
          @members << member
        end
      end
      with_namespace(full_name) do
        node.accept_children(self)
      end
      false
    end

    def visit(node : Crystal::ModuleDef) : Bool
      with_namespace(qualify_name(node.name.full, @current_namespace)) do
        node.body.accept(self)
      end
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      with_namespace(qualify_name(node.name.full, @current_namespace)) do
        node.body.accept(self)
      end
      false
    end

    private def with_namespace(name : String, &)
      prev = @current_namespace
      @current_namespace = name
      yield
      @current_namespace = prev
    end

    private def qualify_name(name : String, namespace : String?) : String
      return name if name.includes?("::")
      return name unless namespace
      "#{namespace}::#{name}"
    end
  end
end
