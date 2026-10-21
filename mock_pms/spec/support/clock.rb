# frozen_string_literal: true

module ClockHelpers
  # Freezes MockPms::Clock at `time` for the rest of the example (or the block).
  def freeze_time(time, &)
    @frozen_at = time.utc
    if block_given?
      MockPms::Clock.with(-> { @frozen_at }, &)
    else
      MockPms::Clock.override = -> { @frozen_at }
    end
  end

  def advance(seconds)
    @frozen_at += seconds
  end
end

RSpec.configure do |config|
  config.include ClockHelpers
  config.after { MockPms::Clock.override = nil }
end
