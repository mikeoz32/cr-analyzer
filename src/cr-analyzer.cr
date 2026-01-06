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

      def handle(request : Types::InitializedNotification)
        Log.info { "Client initialized" }
        nil
      end

      def handle(request : Types::DocumentSymbolRequest)
        Log.error { "Handling document symbol request" }
        @workspace.try do |ws|
          symbols = ws.indexer[request.text_document.uri]
          Types::Response.new(
            request.id,
            symbols
          )
        end
      rescue ex
        Log.error { "Error : #{ex.message}" }
        nil
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
          end
          ws.reindex_file(uri, program)
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
            document_symbol_provider: false,
            definition_provider: true,
            references_provider: true,
            workspace_symbol_provider: true,
            type_definition_provider: true,
            implementation_provider: true,
            document_formatting_provider: false,
            document_range_formatting_provider: false,
            rename_provider: true,
            completion_provider: Types::CompletionOptions.new(trigger_characters: [".", ":", "@", "#", "<", "\"", "'", "/", " "])
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
