require "../../spec_helper"
require "../../../src/cra/workspace"

describe CRA::FacetDocumentStore do
  it "shares stable incremental syntax queries across document updates" do
    with_tmpdir do |dir|
      path = File.join(dir, "sample.cr")
      text = "class Sample\nend\n"
      File.write(path, text)
      uri = "file://#{path}"
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      store = workspace.facet_store

      file_id = store.file_id(uri)
      file_id.should_not be_nil
      first_tree = document.facet_syntax
      first_tree.should_not be_nil
      first_program = document.program
      first_program.should_not be_nil
      executions = store.queries.stats.syntax_executions

      document.update(text)
      store.file_id(uri).should eq(file_id)
      document.facet_syntax.not_nil!.same?(first_tree.not_nil!).should be_true
      document.program.not_nil!.same?(first_program.not_nil!).should be_true
      store.queries.stats.syntax_executions.should eq(executions)
      store.queries.stats.syntax_cache_hits.should be > 0

      document.update("class Sample\n  def value; 1; end\nend\n")
      store.file_id(uri).should eq(file_id)
      store.queries.stats.syntax_executions.should eq(executions + 1)
      document.facet_syntax.not_nil!.nodes(Facet::Compiler::NodeKind::Def).first.name.should eq("value")
    end
  end

  it "applies LSP UTF-16 ranges to source byte offsets" do
    with_tmpdir do |dir|
      path = File.join(dir, "unicode.cr")
      File.write(path, "value = \"😀x\"\n")
      document = workspace_for(dir).document("file://#{path}").not_nil!
      range = CRA::Types::Range.new(
        CRA::Types::Position.new(0, 11),
        CRA::Types::Position.new(0, 12)
      )

      document.apply_changes([
        CRA::Types::TextDocumentContentChangeEvent.new("y", range),
      ])

      document.text.should eq("value = \"😀y\"\n")
      document.facet_syntax.not_nil!.ast.diagnostics.should be_empty
    end
  end

  it "keeps the completed expression at a cursor token boundary" do
    with_tmpdir do |dir|
      path = File.join(dir, "cursor.cr")
      code = "def demo\n  client.fetch\nend\n"
      File.write(path, code)
      document = workspace_for(dir).document("file://#{path}").not_nil!
      offset = code.byte_index("client.fetch").not_nil! + "client.fetch".bytesize
      position = document.facet_syntax.not_nil!.position_at(offset)
      finder = document.facet_node_context(CRA::Types::Position.new(position.line, position.character)).not_nil!

      access = finder.context_path.reverse_each.find { |node| node.call_name == "fetch" }.not_nil!
      access.receiver.try(&.symbol_name).should eq("client")
    end
  end

  it "selects semantic names without losing member receivers or parameter roles" do
    with_tmpdir do |dir|
      path = File.join(dir, "semantic_cursor.cr")
      code = <<-CRYSTAL
        def demo(client : Client)
          client.fetch
        end
      CRYSTAL
      File.write(path, code)
      document = workspace_for(dir).document("file://#{path}").not_nil!
      syntax = document.facet_syntax.not_nil!

      member_offset = code.byte_index("fetch").not_nil! + 2
      member_position = syntax.position_at(member_offset)
      member = document.facet_node_context(
        CRA::Types::Position.new(member_position.line, member_position.character)
      ).not_nil!.semantic_node.not_nil!
      member.call_name.should eq("fetch")
      member.receiver.try(&.symbol_name).should eq("client")

      receiver_offset = code.byte_index("client.fetch").not_nil! + 2
      receiver_position = syntax.position_at(receiver_offset)
      receiver = document.facet_node_context(
        CRA::Types::Position.new(receiver_position.line, receiver_position.character)
      ).not_nil!.semantic_node.not_nil!
      receiver.kind.should eq(Facet::Compiler::NodeKind::Ident)
      receiver.symbol_name.should eq("client")

      parameter_offset = code.byte_index("client :").not_nil! + 2
      parameter_position = syntax.position_at(parameter_offset)
      parameter = document.facet_node_context(
        CRA::Types::Position.new(parameter_position.line, parameter_position.character)
      ).not_nil!.semantic_node.not_nil!
      parameter.kind.should eq(Facet::Compiler::NodeKind::Param)
      parameter.name.should eq("client")

      type_offset = code.byte_index("Client").not_nil! + 2
      type_position = syntax.position_at(type_offset)
      type = document.facet_node_context(
        CRA::Types::Position.new(type_position.line, type_position.character)
      ).not_nil!.semantic_node.not_nil!
      type.kind.should eq(Facet::Compiler::NodeKind::Ident)
      type.symbol_name.should eq("Client")
    end
  end

  it "reindexes the Facet semantic shadow from the current disk revision" do
    with_tmpdir do |dir|
      path = File.join(dir, "semantic.cr")
      uri = "file://#{path}"
      File.write(path, "class Before\nend\n")
      workspace = workspace_for(dir)

      workspace.facet_analyzer.find_class("Before").should_not be_nil
      workspace.facet_analyzer.type_names_for_file(uri).should eq(
        workspace.analyzer.type_names_for_file(uri)
      )

      File.write(path, "class After\n  def value; 1; end\nend\n")
      workspace.reindex_file(uri).should contain(uri)

      workspace.facet_analyzer.find_class("Before").should be_nil
      workspace.facet_analyzer.find_class("After").should_not be_nil
      workspace.facet_analyzer.find_class("After").not_nil!.methods.map(&.name).should contain("value")
      workspace.facet_analyzer.type_names_for_file(uri).should eq(
        workspace.analyzer.type_names_for_file(uri)
      )
    end
  end

  it "does not replace an invalid unsaved Facet revision with disk text" do
    with_tmpdir do |dir|
      path = File.join(dir, "editor.cr")
      uri = "file://#{path}"
      File.write(path, "class Saved\nend\n")
      workspace = workspace_for(dir)
      document = workspace.document(uri).not_nil!
      document.update("class Editing\n  def value(\nend\n")

      document.program.should be_nil
      current_tree = document.facet_syntax.not_nil!
      workspace.reindex_file(uri, document.program).should contain(uri)

      workspace.facet_store.syntax(uri).not_nil!.same?(current_tree).should be_true
      workspace.facet_analyzer.find_class("Saved").should be_nil
      workspace.facet_analyzer.find_class("Editing").should_not be_nil
      workspace.facet_analyzer.find_class("Editing").not_nil!.methods.map(&.name).should contain("value")
    end
  end

  it "caches expanded syntax and exposes invalidated macro consumers" do
    with_tmpdir do |dir|
      macro_path = File.join(dir, "macros.cr")
      use_path = File.join(dir, "use.cr")
      macro_uri = "file://#{macro_path}"
      use_uri = "file://#{use_path}"
      before_macro = <<-CRYSTAL
        macro make_method
          def before
          end
        end
      CRYSTAL
      after_macro = <<-CRYSTAL
        macro make_method
          def after
          end
        end
      CRYSTAL
      use_code = <<-CRYSTAL
        class Box
          make_method
        end
      CRYSTAL
      store = CRA::FacetDocumentStore.new
      store.register(macro_uri, before_macro, macro_path)
      store.register(use_uri, use_code, use_path)
      store.enable_expansion(macro_uri)

      first = store.expanded_syntax(use_uri).not_nil!
      first.nodes(Facet::Compiler::NodeKind::Def).map(&.name).should contain("before")
      executions = store.expansion_queries.stats.expand_executions
      store.expanded_syntax(use_uri).not_nil!.same?(first).should be_true
      store.expansion_queries.stats.expand_executions.should eq(executions)

      store.register(macro_uri, after_macro, macro_path)
      store.pending_expansion_uris.should contain(use_uri)
      second = store.expanded_syntax(use_uri).not_nil!
      second.same?(first).should be_false
      second.nodes(Facet::Compiler::NodeKind::Def).map(&.name).should contain("after")
      store.expansion_queries.stats.expand_executions.should eq(executions + 1)
      store.pending_expansion_uris.should_not contain(use_uri)
    end
  end

  it "reindexes Facet macro-generated declarations after a provider edit" do
    with_tmpdir do |dir|
      macro_path = File.join(dir, "a_macros.cr")
      use_path = File.join(dir, "b_use.cr")
      macro_uri = "file://#{macro_path}"
      use_uri = "file://#{use_path}"
      before_macro = <<-CRYSTAL
        macro make_method
          def before
          end
        end
      CRYSTAL
      after_macro = <<-CRYSTAL
        macro make_method
          def after
          end
        end
      CRYSTAL
      File.write(macro_path, before_macro)
      File.write(use_path, <<-CRYSTAL)
        class Box
          make_method
        end
      CRYSTAL
      workspace = workspace_for(dir)

      before = workspace.facet_analyzer.find_class("Box").not_nil!.methods.find { |method| method.name == "before" }.not_nil!
      before.file.not_nil!.should start_with("facet-macro:")

      document = workspace.document(macro_uri).not_nil!
      document.update(after_macro)
      document.program.should_not be_nil
      reindexed = workspace.reindex_file(macro_uri, document.program)

      reindexed.should contain(use_uri)
      methods = workspace.facet_analyzer.find_class("Box").not_nil!.methods
      methods.map(&.name).should contain("after")
      methods.map(&.name).should_not contain("before")
      methods.find { |method| method.name == "after" }.not_nil!.file.not_nil!.should start_with("facet-macro:")
    end
  end

  it "indexes standard accessor macros through Facet without a stdlib scan" do
    with_tmpdir do |dir|
      path = File.join(dir, "accessors.cr")
      File.write(path, <<-CRYSTAL)
        class User
          property name : String
          class_getter version : Int32
        end
      CRYSTAL
      workspace = workspace_for(dir)
      methods = workspace.facet_analyzer.find_class("User").not_nil!.methods

      methods.map(&.name).should contain("name")
      methods.map(&.name).should contain("name=")
      methods.find { |method| method.name == "name" }.not_nil!.file.not_nil!.should start_with("facet-macro:")
      version = methods.find { |method| method.name == "version" }.not_nil!
      version.class_method.should be_true
      version.file.not_nil!.should start_with("facet-macro:")
    end
  end
end
