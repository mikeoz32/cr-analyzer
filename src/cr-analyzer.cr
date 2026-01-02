require "socket"
require "http"
require "json"
require "./cra/types"
require "log/io_backend"

module CRA
  VERSION = "0.1.0"

  module JsonRPC
    class Processor
      def process(request : Types::Request, output : IO)
        response : JSON::Serializable | Nil = handle(request)
        if response
          body = response.to_json
          output.print "Content-Length: #{body.bytesize}\r\n"
          output.print "\r\n"
          output.print body
        end
      end

      def handle(request : Types::InitializeRequest) : Types::Response
        Log.info { "Handling initialize request" }
        Types::Response.new(request.id)
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
    end

    class RPCRequest
      getter payload : Types::Request
      def self.from_io(io)
        request : Types::Request? = nil
        HTTP.parse_headers_and_body(io) do |headers, body|
          request = Types::Request.from_json(body) if body
        end
        raise "Invalid request" unless request
        new(request)
      end

      def initialize(@payload : Types::Request)
      end

      def inspect
        "#<#{self.class}: #{@jsonrpc}, #{@id}, #{@method}>"
      end
    end

    class Server
      Log = ::Log.for("jsonrpc.server")

      @sockets = [] of Socket::Server
      @listening = false
      @processor = Processor.new

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
            Log.info { "Received request: #{request}" }
            @processor.process(request.payload, output)
          rescue ex
            Log.error { "Error reading request from stdin: #{ex.message}" }
            next
          end
        ensure
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
