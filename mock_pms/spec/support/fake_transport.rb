# frozen_string_literal: true

# Records webhook requests; answers with the queued outcomes, then success.
class FakeTransport
  attr_reader :requests

  def initialize(outcomes = [])
    @outcomes = outcomes
    @requests = []
    @mutex = Mutex.new
  end

  def post(url, body:, headers:)
    @mutex.synchronize { @requests << { url: url, body: body, headers: headers } }
    @outcomes.shift || { outcome: "success", http_status: 200 }
  end
end
