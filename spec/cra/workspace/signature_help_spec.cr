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

private def signature_help_request(uri : String, position : CRA::Types::Position) : CRA::Types::SignatureHelpRequest
  payload = {
    jsonrpc: "2.0",
    id: 1,
    method: "textDocument/signatureHelp",
    params: {
      textDocument: {uri: uri},
      position: {line: position.line, character: position.character},
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::SignatureHelpRequest)
end

describe CRA::Workspace do
  it "returns signature help with documentation and active parameter" do
    code = <<-CRYSTAL
      class Greeter
        # Says hello.
        def greet(name, times = 1)
        end
      end

      def call
        greeter = Greeter.new
        greeter.greet("hi", 2)
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "signature_help.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "greet(\"hi\", 2)")
      pos = position_for(code, index + "greet(\"hi\", ".size)
      request = signature_help_request(uri, pos)
      help = ws.signature_help(request)

      help.should_not be_nil
      help = help.not_nil!
      help.signatures.should_not be_empty
      help.active_parameter.should eq(1)
      help.signatures.first.label.should contain("Greeter#greet")
      doc = help.signatures.first.documentation
      doc.should_not be_nil
      doc_value = doc.not_nil!.as_h["value"].as_s
      doc_value.should contain("Says hello.")
    end
  end

  it "selects the matching overload by arity" do
    code = <<-CRYSTAL
      class Greeter
        def greet(name)
        end

        def greet(name, times)
        end
      end

      def call
        greeter = Greeter.new
        greeter.greet("hi", 2)
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "signature_overload.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "greet(\"hi\", 2)")
      pos = position_for(code, index + "greet(\"hi\", ".size)
      request = signature_help_request(uri, pos)
      help = ws.signature_help(request)

      help.should_not be_nil
      help = help.not_nil!
      help.active_signature.should eq(1)
      help.signatures[1].label.should contain("greet(name, times)")
    end
  end
end
