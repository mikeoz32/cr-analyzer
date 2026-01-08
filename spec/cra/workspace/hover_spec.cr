require "../../spec_helper"
require "../../../src/cra/workspace"

private def index_for(code : String, needle : String, occurrence : Int32 = 0) : Int32
  idx = -1
  (occurrence + 1).times do
    idx = code.index(needle, idx + 1) || raise "needle not found: #{needle}"
  end
  idx
end

private def position_for(code : String, index : Int32) : CRA::Types::Position
  prefix = code[0, index]
  line = prefix.count('\n')
  last_newline = prefix.rindex('\n')
  column = last_newline ? index - last_newline - 1 : index
  CRA::Types::Position.new(line, column)
end

private def hover_request(uri : String, position : CRA::Types::Position) : CRA::Types::HoverRequest
  payload = {
    jsonrpc: "2.0",
    id: 1,
    method: "textDocument/hover",
    params: {
      textDocument: {uri: uri},
      position: {line: position.line, character: position.character},
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::HoverRequest)
end

describe CRA::Workspace do
  it "returns hover signature and documentation" do
    code = <<-CRYSTAL
      class Greeter
        # Says hello.
        def greet(name)
        end
      end

      def call
        greeter = Greeter.new
        greeter.greet("hi")
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "greet(\"hi\")")
      pos = position_for(code, index + "greet".size - 1)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      contents = hover.not_nil!.contents.as_h
      contents["kind"].as_s.should eq("markdown")
      value = contents["value"].as_s
      value.should contain("def Greeter#greet(name)")
      value.should contain("Says hello.")
    end
  end
end
