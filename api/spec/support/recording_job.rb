# frozen_string_literal: true

# A job that counts its runs and can hold a run open until told to finish.
class RecordingJob
  attr_reader :runs

  def initialize(work: 0, hold: nil)
    @runs = 0
    @work = work
    @hold = hold
  end

  def run_once
    @runs += 1
    @hold&.pop
    @work
  end
end
