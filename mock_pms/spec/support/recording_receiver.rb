# frozen_string_literal: true

# A Rack app that records webhook requests and fails the first N with 500.
class RecordingReceiver
  attr_reader :requests

  def initialize(fail_first: 0)
    @fail_first = fail_first
    @requests = Queue.new
    @mutex = Mutex.new
  end

  def call(env)
    body = env["rack.input"].read
    headers = env.select { |k, _| k.start_with?("HTTP_") }.to_h { |k, v| [k.delete_prefix("HTTP_"), v] }
    @requests << { body: body, headers: headers, at: Time.now.utc }
    status = @mutex.synchronize do
      next 200 unless @fail_first.positive?

      @fail_first -= 1
      500
    end
    [status, {}, [status == 200 ? "ok" : "fail"]]
  end
end
