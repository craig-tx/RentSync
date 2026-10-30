# frozen_string_literal: true

module ClockHelpers
  # Freezes Rentsync::Clock at `time` for the rest of the example (or the block).
  def freeze_time(time, &)
    @frozen_at = time.utc
    if block_given?
      Rentsync::Clock.with(-> { @frozen_at }, &)
    else
      Rentsync::Clock.override = -> { @frozen_at }
    end
  end

  def advance(seconds)
    @frozen_at += seconds
  end
end

RSpec.configure do |config|
  config.include ClockHelpers
  config.after { Rentsync::Clock.override = nil }
end
