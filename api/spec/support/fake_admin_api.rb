# frozen_string_literal: true

# Stands in for the mock's /admin/clients: a list, and a create that hands out secrets once.
class FakeAdminApi
  attr_reader :created

  def initialize(existing: [], delay: 0)
    @ids = existing.dup
    @created = []
    @delay = delay
    @mutex = Mutex.new
  end

  def client_ids = @mutex.synchronize { @ids.dup }

  def forget!(id) = @mutex.synchronize { @ids.delete(id) }

  def create_client(name:, redirect_uris:, subscriber_url:)
    sleep @delay
    @mutex.synchronize do
      n = @created.size + 1
      @created << { name: name, redirect_uris: redirect_uris, subscriber_url: subscriber_url }
      @ids << "client_FAKE#{n}"
      { "client_id" => "client_FAKE#{n}", "client_secret" => "CS-SECRET-#{n}", "signing_secret" => "SS-SECRET-#{n}" }
    end
  end
end
