# frozen_string_literal: true

require "spec_helper"

# T019: enc columns hold research R8's envelope, bound to "<table>.<column>:<id>".
RSpec.describe Rentsync::Models::Encrypted do
  def client(key = "mock_pms")
    Rentsync::PmsClient.create_with_secrets(
      { pms_key: key, base_url: "http://pms.test", client_id: "client_#{key}", registered_at: Time.now.utc },
      client_secret: "cs-#{key}", signing_secret: "ss-#{key}"
    )
  end

  it "stores envelopes, never the plaintext, and reads them back" do
    row = client
    stored = Rentsync.db[:pms_clients].where(id: row.id).first
    expect(stored[:client_secret]).to start_with("v1:")
    expect(stored.values.join).not_to include("cs-mock_pms", "ss-mock_pms")
    fresh = Rentsync::PmsClient[row.id]
    expect(fresh.client_secret_plaintext).to eq("cs-mock_pms")
    expect(fresh.signing_secret_plaintext).to eq("ss-mock_pms")
  end

  it "binds each envelope to its row and column" do
    a = client("pms_a")
    b = client("pms_b")
    Rentsync.db[:pms_clients].where(id: b.id).update(client_secret: a.client_secret, signing_secret: a.client_secret)
    stolen = Rentsync::PmsClient[b.id]
    expect { stolen.client_secret_plaintext }.to raise_error(Rentsync::Crypto::Box::Error)
    expect { stolen.signing_secret_plaintext }.to raise_error(Rentsync::Crypto::Box::Error)
  end

  it "clears a secret with nil" do
    row = client
    row.write_secrets!(client_secret: nil)
    expect(Rentsync::PmsClient[row.id].client_secret_plaintext).to be_nil
    expect(Rentsync::PmsClient[row.id].signing_secret_plaintext).to eq("ss-mock_pms")
  end

  it "refuses unsaved rows and unknown columns" do
    expect { Rentsync::PmsClient.new.write_secrets!(client_secret: "x") }.to raise_error(ArgumentError, /save/)
    expect { client.write_secrets!(base_url: "x") }.to raise_error(ArgumentError, /base_url/)
  end

  it "gives connections a con_ public ID and encrypted tokens" do
    operator = Rentsync::Operator.create(email: "ann@example.test", name: "Ann", password_digest: "x")
    expect(operator.public_id).to match(/\Aopr_[0-9A-Z]{20}\z/)
    connection = Rentsync::PmsConnection.create_with_secrets(
      { operator_id: operator.id, pms_client_id: client.id, pms_operator_id: "op_1", pms_operator_name: "Lone Star",
        status: "active" },
      access_token: "at-1", refresh_token: "rt-1"
    )
    expect(connection.public_id).to match(/\Acon_[0-9A-Z]{20}\z/)
    expect(Rentsync::PmsConnection[connection.id].refresh_token_plaintext).to eq("rt-1")
    expect(Rentsync.db[:pms_connections].where(id: connection.id).get(:refresh_token)).not_to include("rt-1")
  end

  it "enforces one active registration per PMS and the connection status values" do
    client
    expect { client }.to raise_error(Sequel::UniqueConstraintViolation)
  end

  it "rejects an unknown connection status" do
    operator = Rentsync::Operator.create(email: "bo@example.test", name: "Bo", password_digest: "x")
    expect do
      Rentsync::PmsConnection.create(operator_id: operator.id, pms_client_id: client.id, pms_operator_id: "op_2",
                                     pms_operator_name: "P", status: "broken")
    end.to raise_error(Sequel::CheckConstraintViolation)
  end
end
