require "../../spec_helper"
require "../../../src/cra/workspace"

describe CRA::Workspace do
  it "returns facet parse diagnostics for bad syntax" do
    with_tmpdir do |dir|
      code = <<-CR
      class Foo
        def bar(
      end
      CR
      path = File.join(dir, "bad.cr")
      File.write(path, code)
      ws = workspace_for(dir)

      request = CRA::Types::Message.from_json(%({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "textDocument/diagnostic",
        "params": {
          "textDocument": {"uri": "file://#{path}"}
        }
      })).as(CRA::Types::DocumentDiagnosticRequest)

      report = ws.document_diagnostics(request)
      report.should be_a(CRA::Types::DocumentDiagnosticReportFull)
      report = report.as(CRA::Types::DocumentDiagnosticReportFull)
      report.items.size.should be > 0
      report.items.first.source.should eq("facet")
      report.items.first.severity.should eq(CRA::Types::DiagnosticSeverity::Error)
    end
  end
end

describe CRA::Workspace do
  it "uses crystal parser fallback diagnostics when facet is disabled" do
    with_tmpdir do |dir|
      code = <<-CR
      class Foo
        def bar(
      end
      CR
      path = File.join(dir, "bad.cr")
      File.write(path, code)
      ws = workspace_for(dir)
      begin
        ENV["CRA_DISABLE_FACET_DIAGNOSTICS"] = "1"
        request = CRA::Types::Message.from_json(%({
          "jsonrpc": "2.0",
          "id": 1,
          "method": "textDocument/diagnostic",
          "params": {
            "textDocument": {"uri": "file://#{path}"}
          }
        })).as(CRA::Types::DocumentDiagnosticRequest)

        report = ws.document_diagnostics(request)
        report.should be_a(CRA::Types::DocumentDiagnosticReportFull)
        report = report.as(CRA::Types::DocumentDiagnosticReportFull)
        report.items.size.should be > 0
        report.items.first.source.should eq("crystal-parser")
      ensure
        ENV.delete("CRA_DISABLE_FACET_DIAGNOSTICS")
      end
    end
  end

  it "emits TODO warnings" do
    with_tmpdir do |dir|
      code = <<-CR
      class Foo
        # TODO: fix it
        def bar; end
      end
      CR
      path = File.join(dir, "todo.cr")
      File.write(path, code)
      ws = workspace_for(dir)

      request = CRA::Types::Message.from_json(%({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "textDocument/diagnostic",
        "params": {
          "textDocument": {"uri": "file://#{path}"}
        }
      })).as(CRA::Types::DocumentDiagnosticRequest)

      report = ws.document_diagnostics(request).as(CRA::Types::DocumentDiagnosticReportFull)
      report.items.any? { |d| d.source == "todo" && d.severity == CRA::Types::DiagnosticSeverity::Warning }.should be_true
    end
  end

  it "emits duplicate require hint" do
    with_tmpdir do |dir|
      code = <<-CR
      require "foo"
      require "foo"
      CR
      path = File.join(dir, "dup.cr")
      File.write(path, code)
      ws = workspace_for(dir)

      request = CRA::Types::Message.from_json(%({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "textDocument/diagnostic",
        "params": {
          "textDocument": {"uri": "file://#{path}"}
        }
      })).as(CRA::Types::DocumentDiagnosticRequest)

      report = ws.document_diagnostics(request).as(CRA::Types::DocumentDiagnosticReportFull)
      report.items.any? { |d| d.source == "lint" && d.severity == CRA::Types::DiagnosticSeverity::Hint }.should be_true
    end
  end

  it "warns on empty rescue" do
    with_tmpdir do |dir|
      code = <<-CR
      begin
        foo
      rescue
      end
      CR
      path = File.join(dir, "rescue.cr")
      File.write(path, code)
      ws = workspace_for(dir)

      request = CRA::Types::Message.from_json(%({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "textDocument/diagnostic",
        "params": {
          "textDocument": {"uri": "file://#{path}"}
        }
      })).as(CRA::Types::DocumentDiagnosticRequest)

      report = ws.document_diagnostics(request).as(CRA::Types::DocumentDiagnosticReportFull)
      report.items.any? { |d| d.source == "lint" && d.severity == CRA::Types::DiagnosticSeverity::Warning && d.message.includes?("Empty rescue") }.should be_true
    end
  end

  it "warns on empty rescue" do
    with_tmpdir do |dir|
      code = <<-CR
      begin
        foo
      rescue
      end
      CR
      path = File.join(dir, "empty_rescue.cr")
      File.write(path, code)
      ws = workspace_for(dir)

      params = ws.publish_diagnostics("file://#{path}")
      params.diagnostics.any? { |d| d.source == "lint" && d.message.includes?("Empty rescue") }.should be_true
    end
  end

  it "does not warn on non-empty rescue" do
    with_tmpdir do |dir|
      code = <<-CR
      begin
        foo
      rescue
        ch.send(nil)
      end
      CR
      path = File.join(dir, "rescue_body.cr")
      File.write(path, code)
      ws = workspace_for(dir)

      params = ws.publish_diagnostics("file://#{path}")
      params.diagnostics.any? { |d| d.message.includes?("Empty rescue") }.should be_false
    end
  end

  it "hints trailing whitespace" do
    with_tmpdir do |dir|
      code = <<-CR
      class Foo  
      end
      CR
      path = File.join(dir, "trail.cr")
      File.write(path, code)
      ws = workspace_for(dir)

      request = CRA::Types::Message.from_json(%({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "textDocument/diagnostic",
        "params": {
          "textDocument": {"uri": "file://#{path}"}
        }
      })).as(CRA::Types::DocumentDiagnosticRequest)

      report = ws.document_diagnostics(request).as(CRA::Types::DocumentDiagnosticReportFull)
      report.items.any? { |d| d.source == "lint" && d.severity == CRA::Types::DiagnosticSeverity::Hint && d.message.includes?("Trailing whitespace") }.should be_true
    end
  end

  it "hints unused def args" do
    with_tmpdir do |dir|
      code = <<-CR
      def foo(a, _b, c)
        c
      end
      CR
      path = File.join(dir, "args.cr")
      File.write(path, code)
      ws = workspace_for(dir)

      request = CRA::Types::Message.from_json(%({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "textDocument/diagnostic",
        "params": {
          "textDocument": {"uri": "file://#{path}"}
        }
      })).as(CRA::Types::DocumentDiagnosticRequest)

      report = ws.document_diagnostics(request).as(CRA::Types::DocumentDiagnosticReportFull)
      report.items.any? { |d| d.source == "lint" && d.message.includes?("Unused argument 'a'") }.should be_true
      report.items.any? { |d| d.message.includes?("Unused argument '_b'") }.should be_false
      report.items.any? { |d| d.message.includes?("Unused argument 'c'") }.should be_false
    end
  end

  it "publishes diagnostics params" do
    with_tmpdir do |dir|
      code = <<-CR
      class Foo  
      end
      CR
      path = File.join(dir, "pub.cr")
      File.write(path, code)
      ws = workspace_for(dir)

      params = ws.publish_diagnostics("file://#{path}")
      params.should be_a(CRA::Types::PublishDiagnosticsParams)
      params.diagnostics.any? { |d| d.source == "lint" }.should be_true
    end
  end

  it "warns on mixed indentation and missing newline" do
    with_tmpdir do |dir|
      code = "def foo\n\t  bar\nend"
      path = File.join(dir, "indent.cr")
      File.write(path, code)
      ws = workspace_for(dir)

      params = ws.publish_diagnostics("file://#{path}")
      params.diagnostics.any? { |d| d.message.includes?("Mixed tabs and spaces") }.should be_true
      params.diagnostics.any? { |d| d.message.includes?("does not end with a newline") }.should be_true
    end
  end

  it "does not flag abstract def params as unused" do
    with_tmpdir do |dir|
      code = <<-CR
      abstract class Foo
        abstract def foo(a, _b, c)
        abstract def bar(a : Int32) : String
      end
      CR
      path = File.join(dir, "abstract_args.cr")
      File.write(path, code)
      ws = workspace_for(dir)

      params = ws.publish_diagnostics("file://#{path}")
      params.diagnostics.any? { |d| d.source == "lint" && d.message.includes?("Unused argument") }.should be_false
    end
  end

  it "hints unused block args" do
    with_tmpdir do |dir|
      code = <<-CR
      [1,2,3].each do |x, y|
        x
      end
      CR
      path = File.join(dir, "block_args.cr")
      File.write(path, code)
      ws = workspace_for(dir)

      params = ws.publish_diagnostics("file://#{path}")
      params.diagnostics.any? { |d| d.message.includes?("Unused block argument 'y'") }.should be_true
      params.diagnostics.any? { |d| d.message.includes?("Unused block argument 'x'") }.should be_false
    end
  end
end
