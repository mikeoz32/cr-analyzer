require "../../spec_helper"
require "../../../src/cra/workspace"

private def incremental_position_for(code : String, needle : String) : CRA::Types::Position
  index = code.index(needle) || raise "needle not found: #{needle}"
  prefix = code.byte_slice(0, index) || ""
  line = prefix.count('\n')
  last_newline = prefix.rindex('\n')
  column = last_newline ? index - last_newline - 1 : index
  CRA::Types::Position.new(line, column)
end

private def incremental_declaration_request(
  uri : String,
  position : CRA::Types::Position,
) : CRA::Types::DeclarationRequest
  CRA::Types::Message.from_json({
    jsonrpc: "2.0",
    id:      1,
    method:  "textDocument/declaration",
    params:  {
      textDocument: {uri: uri},
      position:     {line: position.line, character: position.character},
    },
  }.to_json).as(CRA::Types::DeclarationRequest)
end

describe CRA::Workspace do
  it "reindexes dependent files when superclass changes" do
    with_tmpdir do |dir|
      base_path = File.join(dir, "base.cr")
      child_path = File.join(dir, "child.cr")

      File.write(base_path, <<-CRYSTAL)
        class Base
          def greet
          end
        end
      CRYSTAL

      child_code = <<-CRYSTAL
        class Child < Base
          def call
            greet
          end
        end
      CRYSTAL
      File.write(child_path, child_code)

      ws = workspace_for(dir)
      child_uri = "file://#{child_path}"
      position = incremental_position_for(child_code, "greet")
      request = incremental_declaration_request(child_uri, position)

      declarations = ws.find_declarations(request)
      declarations.size.should eq(1)
      declarations.first.uri.should eq("file://#{base_path}")

      File.write(base_path, <<-CRYSTAL)
        class Base
        end
      CRYSTAL

      reindexed = ws.reindex_file("file://#{base_path}")
      reindexed.should contain(child_uri)

      ws.find_declarations(request).should be_empty
    end
  end

  it "reindexes dependent files when included module changes" do
    with_tmpdir do |dir|
      module_path = File.join(dir, "mixins.cr")
      child_path = File.join(dir, "child.cr")

      File.write(module_path, <<-CRYSTAL)
        module Mixins
          def greet
          end
        end
      CRYSTAL

      child_code = <<-CRYSTAL
        class Child
          include Mixins

          def call
            greet
          end
        end
      CRYSTAL
      File.write(child_path, child_code)

      ws = workspace_for(dir)
      child_uri = "file://#{child_path}"
      position = incremental_position_for(child_code, "greet")
      request = incremental_declaration_request(child_uri, position)

      declarations = ws.find_declarations(request)
      declarations.size.should eq(1)
      declarations.first.uri.should eq("file://#{module_path}")

      File.write(module_path, <<-CRYSTAL)
        module Mixins
        end
      CRYSTAL

      reindexed = ws.reindex_file("file://#{module_path}")
      reindexed.should contain(child_uri)

      ws.find_declarations(request).should be_empty
    end
  end
end
