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
end
