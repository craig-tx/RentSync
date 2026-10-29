# frozen_string_literal: true

require "spec_helper"

# T030: one RentSync operator per mock PMS operator, signing in with the seed password.
RSpec.describe Rentsync::Seed::Operators do
  it "creates operator<n>@example.test for each mock PMS operator, with the seed password" do
    described_class.ensure!
    expect(Rentsync::Operator.order(:id).select_map(%i[email name])).to eq(
      [["operator1@example.test", "Lone Star Rentals"], ["operator2@example.test", "Prairie Homes"],
       ["operator3@example.test", "Bluebonnet Property Co"]]
    )
    signed_in = Rentsync::Auth::Passwords.authenticate("operator2@example.test", "test-operator-password")
    expect(signed_in&.name).to eq("Prairie Homes")
  end

  it "is idempotent" do
    described_class.ensure!
    ids = Rentsync::Operator.select_map(:id)
    described_class.ensure!
    expect(Rentsync::Operator.select_map(:id)).to eq(ids)
  end

  it "maps operator n to the mock's login for bin/connect_operator" do
    expect(described_class.pms_login(1)).to eq("lonestar")
    expect(described_class.pms_login(3)).to eq("bluebonnet")
    expect { described_class.pms_login(4) }.to raise_error(ArgumentError)
  end
end
