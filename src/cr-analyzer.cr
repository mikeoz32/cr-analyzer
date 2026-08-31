require "socket"
require "http"
require "json"
require "./cra/types"
require "./cra/workspace"
require "log/io_backend"

module CRA
  VERSION = "0.1.0"

  module JsonRPC
    class Processor
      @workspace : Workspace? = nil

      def initialize(@server : Server)
      end

      def process(request, output : IO)
        response : JSON::Serializable | Nil = handle(request)
        if response
          @server.send(response)
        end
      end

      def handle(request : Types::Message)
        Log.warn { "Unhandled request type: #{request.class}" }
        nil
      end

      def handle(request : Types::CompletionRequest)
        Log.error { "Handling completion request" }
        @workspace.try do |ws|
          return Types::Response.new(
            request.id,
            Types::CompletionList.new(
              is_incomplete: false,
              items: ws.complete(request)))
        end
        Types::Response.new(
          request.id,
          Types::CompletionList.new(
            is_incomplete: false,
            items: [] of Types::CompletionItem))
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::CompletionItemResolveRequest)
        Log.error { "Handling completion resolve request" }
        @workspace.try do |ws|
          item = ws.resolve_completion_item(request.item)
          return Types::Response.new(request.id, item)
        end
        Types::Response.new(request.id, request.item)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::HoverRequest)
        Log.error { "Handling hover request" }
        @workspace.try do |ws|
          hover = ws.hover(request)
          return Types::Response.new(request.id, hover) if hover
        end
        Types::Response.new(request.id, nil)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::SignatureHelpRequest)
        Log.error { "Handling signature help request" }
        @workspace.try do |ws|
          signature_help = ws.signature_help(request)
          return Types::Response.new(request.id, signature_help) if signature_help
        end
        Types::Response.new(request.id, nil)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::DocumentHighlightRequest)
        Log.error { "Handling document highlight request" }
        @workspace.try do |ws|
          return Types::Response.new(request.id, ws.document_highlights(request))
        end
        Types::Response.new(request.id, [] of Types::DocumentHighlight)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::SelectionRangeRequest)
        Log.error { "Handling selection range request" }
        @workspace.try do |ws|
          return Types::Response.new(request.id, ws.selection_ranges(request))
        end
        Types::Response.new(request.id, [] of Types::SelectionRange)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::ReferencesRequest)
        Log.error { "Handling references request" }
        @workspace.try do |ws|
          refs = ws.find_references(request)
          return Types::Response.new(request.id, refs)
        end
        Types::Response.new(request.id, [] of Types::Location)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::CallHierarchyPrepareRequest)
        Log.error { "Handling call hierarchy prepare request" }
        @workspace.try do |ws|
          items = ws.prepare_call_hierarchy(request)
          return Types::Response.new(request.id, items)
        end
        Types::Response.new(request.id, [] of Types::CallHierarchyItem)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::CallHierarchyIncomingCallsRequest)
        Log.error { "Handling call hierarchy incoming calls request" }
        @workspace.try do |ws|
          calls = ws.call_hierarchy_incoming(request)
          return Types::Response.new(request.id, calls)
        end
        Types::Response.new(request.id, [] of Types::CallHierarchyIncomingCall)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::CallHierarchyOutgoingCallsRequest)
        Log.error { "Handling call hierarchy outgoing calls request" }
        @workspace.try do |ws|
          calls = ws.call_hierarchy_outgoing(request)
          return Types::Response.new(request.id, calls)
        end
        Types::Response.new(request.id, [] of Types::CallHierarchyOutgoingCall)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::TypeHierarchyPrepareRequest)
        Log.error { "Handling type hierarchy prepare request" }
        @workspace.try do |ws|
          items = ws.prepare_type_hierarchy(request)
          return Types::Response.new(request.id, items)
        end
        Types::Response.new(request.id, [] of Types::TypeHierarchyItem)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::TypeHierarchySupertypesRequest)
        Log.error { "Handling type hierarchy supertypes request" }
        @workspace.try do |ws|
          items = ws.type_hierarchy_supertypes(request)
          return Types::Response.new(request.id, items)
        end
        Types::Response.new(request.id, [] of Types::TypeHierarchyItem)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::TypeHierarchySubtypesRequest)
        Log.error { "Handling type hierarchy subtypes request" }
        @workspace.try do |ws|
          items = ws.type_hierarchy_subtypes(request)
          return Types::Response.new(request.id, items)
        end
        Types::Response.new(request.id, [] of Types::TypeHierarchyItem)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::InitializedNotification)
        Log.info { "Client initialized" }
        nil
      end

      def handle(request : Types::DocumentSymbolRequest)
        Log.error { "Handling document symbol request" }
        @workspace.try do |ws|
          symbols = ws.document_symbols(request.text_document.uri)
          Types::Response.new(
            request.id,
            symbols
          )
        end
      rescue ex
        Log.error { "Error : #{ex.message}" }
        nil
      end

      def handle(request : Types::RenameRequest)
        Log.error { "Handling rename request" }
        @workspace.try do |ws|
          edit = ws.rename(request)
          return Types::Response.new(request.id, edit) if edit
        end
        Types::Response.new(request.id, nil)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::PrepareRenameRequest)
        Log.error { "Handling prepare rename request" }
        @workspace.try do |ws|
          range = ws.prepare_rename(request)
          return Types::Response.new(request.id, range) if range
        end
        Types::Response.new(request.id, nil)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::WorkspaceSymbolRequest)
        Log.error { "Handling workspace symbol request" }
        @workspace.try do |ws|
          symbols = ws.workspace_symbols(request)
          return Types::Response.new(request.id, symbols)
        end
        Types::Response.new(request.id, [] of Types::SymbolInformation)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::DocumentDiagnosticRequest)
        Log.error { "Handling document diagnostic request" }
        @workspace.try do |ws|
          report = ws.document_diagnostics(request)
          return Types::Response.new(request.id, report)
        end
        Types::Response.new(request.id, Types::DocumentDiagnosticReportFull.new([] of Types::Diagnostic))
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::WorkspaceDiagnosticRequest)
        Log.error { "Handling workspace diagnostic request" }
        # Only document diagnostics supported for now.
        Types::Response.new(request.id, Types::WorkspaceDiagnosticReport.new([] of Types::WorkspaceDocumentDiagnosticReport))
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      # Notifications are no-ops server-side; client controls publish.
      def handle(request : Types::DidChangeConfigurationNotification)
        Log.info { "Configuration changed: #{request.to_json}" }
        nil
      end

      def handle(request : Types::DeclarationRequest)
        Log.error { "Handling declaration request" }
        @workspace.try do |ws|
          locations = ws.find_declarations(request)
          Types::Response.new(
            request.id,
            locations
          )
        end
      end

      def handle(request : Types::DefinitionRequest)
        Log.error { "Handling definition request" }
        @workspace.try do |ws|
          locations = ws.find_definitions(request)
          Types::Response.new(
            request.id,
            locations
          )
        end
      end

      def handle(request : Types::TypeDefinitionRequest)
        Log.error { "Handling type definition request" }
        @workspace.try do |ws|
          locations = ws.find_type_definitions(request)
          Types::Response.new(
            request.id,
            locations
          )
        end
      end

      def handle(request : Types::ImplementationRequest)
        Log.error { "Handling implementation request" }
        @workspace.try do |ws|
          locations = ws.find_implementations(request)
          Types::Response.new(
            request.id,
            locations
          )
        end
      end

      def handle(request : Types::InlineValueRequest)
        Log.error { "Handling inline value request" }
        @workspace.try do |ws|
          values = ws.inline_values(request)
          return Types::Response.new(request.id, values)
        end
        Types::Response.new(request.id, [] of Types::InlineValue)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::DidOpenTextDocumentNotification)
        Log.info { "Handling didOpen notification" }
        @workspace.try do |ws|
          uri = request.text_document.uri
          document = ws.document(uri)
          program = nil
          begin
            document.try &.update(request.text_document.text)
            program = document.try(&.program)
          rescue ex
            Log.error { "Error parsing #{uri}: #{ex.message}" }
          end
          ws.reindex_file(uri, program)
          ws_diag = ws.publish_diagnostics(uri)
          @server.send(Types::PublishDiagnosticsNotification.new(ws_diag))
        end
        nil
      end

      def handle(request : Types::DidChangeTextDocumentNotification)
        Log.info { "Handling didChange notification" }
        @workspace.try do |ws|
          uri = request.text_document.uri
          document = ws.document(uri)
          program = nil
          begin
            document.try &.apply_changes(request.content_changes)
            program = document.try(&.program)
          rescue ex
            Log.error { "Error parsing #{uri}: #{ex.message}" }
            return nil
          end
          ws.reindex_file(uri, program)
          ws_diag = ws.publish_diagnostics(uri)
          @server.send(Types::PublishDiagnosticsNotification.new(ws_diag))
        end
        nil
      end

      def handle(request : Types::DidSaveTextDocumentNotification)
        Log.info { "Handling didSave notification" }
        @workspace.try do |ws|
          uri = request.text_document.uri
          if text = request.text
            document = ws.document(uri)
            program = nil
            begin
              document.try &.update(text)
              program = document.try(&.program)
            rescue ex
              Log.error { "Error parsing #{uri}: #{ex.message}" }
            end
            ws.reindex_file(uri, program)
          else
            ws.reindex_file(uri)
          end
          ws_diag = ws.publish_diagnostics(uri)
          @server.send(Types::PublishDiagnosticsNotification.new(ws_diag))
        end
        nil
      end

      def handle(request : Types::DidCloseTextDocumentNotification)
        Log.info { "Handling didClose notification" }
        nil
      end

      def handle(request : Types::InitializeRequest)
        Log.error { "Handling initialize request" }
        request.root_uri.try do |uri|
          @workspace = Workspace.from_s(uri)
          @workspace.try &.scan
        end
        Types::Response.new(request.id, Types::InitializeResult.new(
          capabilities: Types::ServerCapabilities.new(
            text_document_sync: Types::TextDocumentSyncOptions.new(
              open_close: true,
              change: Types::TextDocumentSyncKind::Incremental,
              save: Types::SaveOptions.new(include_text: true)
            ),
            document_symbol_provider: true,
            declaration_provider: true,
            definition_provider: true,
            hover_provider: true,
            references_provider: true,
            workspace_symbol_provider: true,
            type_definition_provider: true,
            implementation_provider: true,
            type_hierarchy_provider: true,
            signature_help_provider: Types::SignatureHelpOptions.new(trigger_characters: ["(", ","]),
            document_highlight_provider: true,
            document_formatting_provider: false,
            document_range_formatting_provider: false,
            rename_provider: Types::RenameOptions.new(prepare_provider: true),
            completion_provider: Types::CompletionOptions.new(resolve_provider: true, trigger_characters: [".", ":", "@", "#", "<", "\"", "'", "/", " "]),
            selection_range_provider: true,
            call_hierarchy_provider: true,
            inline_value_provider: true,
            diagnostic_provider: Types::DiagnosticOptions.new(
              inter_file_dependencies: false,
              workspace_diagnostics: false
            )
          )
        ))
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end
    end

    class RPCRequest
      getter payload : Types::Message

      def self.from_io(io)
        request : Types::Message? = nil
        HTTP.parse_headers_and_body(io) do |headers, body|
          request = Types::Message.from_json(body) if body
        end
        raise "Invalid request" unless request
        new(request)
      end

      def initialize(@payload : Types::Message)
      end
    end

    class Server
      Log = ::Log.for("jsonrpc.server")

      @sockets = [] of Socket::Server
      @listening = false

      @input = STDIN
      @output = STDOUT

      def initialize(processor : Processor | Nil = nil)
        @sockets = [] of Socket::Server
        @listening = false
        @processor = processor || Processor.new(self)
      end

      def send(data)
        body = data.to_json
        @output.print "Content-Length: #{body.bytesize}\r\n"
        @output.print "\r\n"
        @output.print body
        Log.info { "Sent response: #{body}" }
      ensure
        @output.flush
      end

      def bind(server : Socket::Server)
        @sockets << server
        puts "Server bound to #{server}"
      end

      def listen
        ::Log.setup(backend: ::Log::IOBackend.new(io: STDERR))
        @listening = true

        done = Channel(Nil).new

        spawn do
          input = STDIN
          output = STDOUT

          loop do
            request = RPCRequest.from_io(input)
            Log.info { "Received request: #{request.payload.to_json}" }
            @processor.as(Processor).process(request.payload, output)
          rescue ex
            Log.error { "Error reading request from stdin: #{ex.message}" }
            break
          end
        ensure
          Log.info { "Shutting down stdin listener" }
          done.send(nil)
        end

        @sockets.each do |socket|
          spawn do
            loop do
              io = begin
                socket.accept?
              rescue ex
                Log.error { "Error accepting connection: #{ex.message}" }
                next
              end
              if io
                request = RPCRequest.from_io(io)
                Log.info { "Received request: #{request}" }
                io.close
              else
                Log.error { "Error accepting connection: #{io}" }
                break
              end
            end
          ensure
            done.send(nil)
          end
        end
        (@sockets.size + 1).times { done.receive }
      end
    end
  end
end
