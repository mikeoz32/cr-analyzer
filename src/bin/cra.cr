require "../cr-analyzer"

server = CRA::JsonRPC::Server.new

# if addr = ENV["CRA_LISTEN_TCP"]?
#   if addr.includes?(":")
#     host, port_str = addr.split(":", 2)
#     port = port_str.to_i
#     server.bind(TCPServer.new(host, port))
#   else
#     Log.warn { "CRA_LISTEN_TCP must be host:port; ignoring '#{addr}'" }
#   end
# end

server.listen
