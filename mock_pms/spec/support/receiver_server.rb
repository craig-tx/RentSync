# frozen_string_literal: true

require "puma"
require "puma/configuration"
require "puma/launcher"
require "socket"

# Runs a Rack app on a throwaway local Puma, for specs that need a real HTTP receiver.
module ReceiverServer
  module_function

  def start(app)
    port = free_port
    config = Puma::Configuration.new do |c|
      c.bind "tcp://127.0.0.1:#{port}"
      c.app app
      c.threads 1, 4
      c.workers 0
      c.log_requests false
      c.quiet
    end
    launcher = Puma::Launcher.new(config, log_writer: Puma::LogWriter.null)
    thread = Thread.new { launcher.run }
    sleep 0.05 until open?(port)
    [port, -> { launcher.stop || thread.join(5) }]
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1].tap { server.close }
  end

  def open?(port)
    TCPSocket.new("127.0.0.1", port).close
    true
  rescue Errno::ECONNREFUSED
    false
  end
end
