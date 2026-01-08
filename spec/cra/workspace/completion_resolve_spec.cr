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

private def completion_request(uri : String, position : CRA::Types::Position, trigger_char : String? = nil) : CRA::Types::CompletionRequest
  context = if trigger_char
              {triggerKind: 2, triggerCharacter: trigger_char}
            else
              {triggerKind: 1}
            end

  payload = {
    jsonrpc: "2.0",
    id: 1,
    method: "textDocument/completion",
    params: {
      textDocument: {uri: uri},
      position: {line: position.line, character: position.character},
      context: context,
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::CompletionRequest)
end

describe CRA::Workspace do
  it "resolves completion item documentation" do
    code = <<-CRYSTAL
      class Greeter
        # Says hello.
        def greet(name)
        end
      end

      def call
        greeter = Greeter.new
        greeter.gr
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "main.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "greeter.gr") + "greeter.gr".size
      pos = position_for(code, index)
      request = completion_request(uri, pos, ".")
      items = ws.complete(request)

      item = items.find { |entry| entry.label == "greet" }
      item.should_not be_nil
      item = item.not_nil!

      resolved = ws.resolve_completion_item(item)
      resolved.documentation.should_not be_nil
      contents = resolved.documentation.not_nil!.as_h
      contents["kind"].as_s.should eq("markdown")
      value = contents["value"].as_s
      value.should contain("def Greeter#greet(name)")
      value.should contain("Says hello.")
    end
  end

  it "resolves type completion documentation" do
    code = <<-CRYSTAL
      # Handles greetings.
      class Greeter
      end

      def call
        Gre
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "types.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "Gre") + "Gre".size
      pos = position_for(code, index)
      request = completion_request(uri, pos)
      items = ws.complete(request)

      item = items.find { |entry| entry.label == "Greeter" }
      item.should_not be_nil
      item = item.not_nil!

      resolved = ws.resolve_completion_item(item)
      resolved.documentation.should_not be_nil
      contents = resolved.documentation.not_nil!.as_h
      contents["kind"].as_s.should eq("markdown")
      value = contents["value"].as_s
      value.should contain("class Greeter")
      value.should contain("Handles greetings.")
    end
  end
end
