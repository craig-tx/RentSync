# frozen_string_literal: true

require "spec_helper"

# T010, research R8: AES-256-GCM envelopes bound to their row and column.
RSpec.describe Rentsync::Crypto::Box do
  let(:k1) { Random.new(1).bytes(32) }
  let(:k2) { Random.new(2).bytes(32) }
  let(:config) { "k1=#{[k1].pack('m0')},k2=#{[k2].pack('m0')}" }
  let(:box) { described_class.new(config) }
  let(:aad) { "pms_connections.refresh_token:42" }

  it "round-trips" do
    envelope = box.encrypt("refresh-abc", aad: aad)
    expect(box.decrypt(envelope, aad: aad)).to eq("refresh-abc")
  end

  it "round-trips empty and non-ASCII text" do
    ["", "pässwörd ✓"].each do |text|
      expect(box.decrypt(box.encrypt(text, aad: aad), aad: aad)).to eq(text)
    end
  end

  it "writes v1:<key_id>:<nonce>:<ciphertext+tag> with a 12-byte nonce and a 16-byte tag" do
    version, key_id, nonce, sealed = box.encrypt("secret", aad: aad).split(":")
    expect(version).to eq("v1")
    expect(key_id).to eq("k1")
    expect(nonce.unpack1("m0").bytesize).to eq(12)
    expect(sealed.unpack1("m0").bytesize).to eq("secret".bytesize + 16)
  end

  it "uses a fresh nonce each time" do
    a = box.encrypt("same", aad: aad)
    b = box.encrypt("same", aad: aad)
    expect(a).not_to eq(b)
    expect(a.split(":")[2]).not_to eq(b.split(":")[2])
  end

  it "never contains the plaintext" do
    expect(box.encrypt("visible-token", aad: aad)).not_to include("visible-token")
  end

  it "refuses another row's or column's associated data" do
    envelope = box.encrypt("refresh-abc", aad: aad)
    ["pms_connections.refresh_token:43", "pms_connections.access_token:42"].each do |other|
      expect { box.decrypt(envelope, aad: other) }.to raise_error(described_class::Error)
    end
  end

  it "refuses a flipped ciphertext bit" do
    version, key_id, nonce, sealed = box.encrypt("refresh-abc", aad: aad).split(":")
    bytes = sealed.unpack1("m0").bytes
    bytes[0] ^= 1
    tampered = [version, key_id, nonce, [bytes.pack("C*")].pack("m0")].join(":")
    expect { box.decrypt(tampered, aad: aad) }.to raise_error(described_class::Error)
  end

  it "encrypts with the first key and decrypts with any listed key" do
    old = described_class.new("k2=#{[k2].pack('m0')}").encrypt("from-k2", aad: aad)
    expect(old.split(":")[1]).to eq("k2")
    expect(box.decrypt(old, aad: aad)).to eq("from-k2")
    expect(box.encrypt("x", aad: aad).split(":")[1]).to eq("k1")
  end

  it "refuses an unknown key ID" do
    other = described_class.new("k9=#{[k2].pack('m0')}").encrypt("x", aad: aad)
    expect { box.decrypt(other, aad: aad) }.to raise_error(described_class::Error, /k9/)
  end

  it "refuses malformed envelopes" do
    ["", "v1:k1:abc", "v2:k1:#{['n' * 12].pack('m0')}:#{['c' * 20].pack('m0')}", "plain text"].each do |bad|
      expect { box.decrypt(bad, aad: aad) }.to raise_error(described_class::Error)
    end
  end

  describe "key configuration" do
    secret = ["S" * 32].pack("m0")

    [
      "",
      "k1",
      "k1=",
      "=#{secret}",
      "k1=#{['short'].pack('m0')}",
      "k1=!!not base64!!",
      "k1=#{secret},k1=#{secret}",
      "bad id=#{secret}"
    ].each do |bad|
      it "fails at load for #{bad.empty? ? 'an empty value' : bad.sub(secret, '<key>').inspect}, never showing a key" do
        expect { described_class.new(bad) }.to raise_error(described_class::ConfigError) { |e|
          expect(e.message).to include("RENTSYNC_ENCRYPTION_KEYS")
          expect(e.message).not_to include(secret)
          expect(e.message).not_to include("S" * 8)
        }
      end
    end
  end
end
