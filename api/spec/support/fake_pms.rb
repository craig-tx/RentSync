# frozen_string_literal: true

# A stand-in PMS API on a local Puma (research R17): answers from a script, in order, and
# records every request. An answer is [status, headers, body], a Proc returning one, or
# :hang to never answer within the client's timeout. The last answer repeats.
class FakePms
  Request = Struct.new(:path, :query, :authorization)

  attr_reader :requests, :port

  def initialize
    @script = [[200, {}, { data: [], next_cursor: nil }]]
    @requests = []
    @mutex = Mutex.new
  end

  def start
    @port, @stop = ReceiverServer.start(self)
    self
  end

  def stop = @stop&.call

  def base_url = "http://127.0.0.1:#{@port}"

  def script(*answers)
    @mutex.synchronize { @script = answers }
    self
  end

  def call(env)
    answer = @mutex.synchronize do
      @requests << Request.new(env["PATH_INFO"], Rack::Utils.parse_query(env["QUERY_STRING"]),
                               env["HTTP_AUTHORIZATION"])
      @script.length > 1 ? @script.shift : @script.first
    end
    answer = answer.call(@requests.last) if answer.respond_to?(:call)
    if answer == :hang
      sleep 2
      answer = [200, {}, {}]
    end
    status, headers, body = answer
    [status, { "content-type" => "application/json" }.merge(headers), [body.is_a?(String) ? body : JSON.generate(body)]]
  end
end
