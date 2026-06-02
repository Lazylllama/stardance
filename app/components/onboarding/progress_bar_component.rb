module Onboarding
  class ProgressBarComponent < ViewComponent::Base
    STEPS = %i[birthday experience experience_result interests interests_result referral name done].freeze
    STEP_FRACTIONS = STEPS.each_with_index.to_h { |slug, i| [ slug, (i + 1).to_f / STEPS.size ] }.freeze

    # Steps prior to the progress bar's first frame; back from birthday lands here.
    ENTRY_STEP = :welcome

    attr_reader :step

    def initialize(step:)
      @step = step.to_sym
    end

    def fill_percentage
      (STEP_FRACTIONS.fetch(step, 0) * 100).round
    end

    def previous_fill_percentage
      idx = STEPS.index(step)
      raise ArgumentError, "Unknown progress-bar step: #{step.inspect}" if idx.nil?

      prev_idx = going_back? ? idx + 1 : idx - 1
      return 0 if prev_idx.negative?
      return 100 if prev_idx >= STEPS.size

      (STEP_FRACTIONS.fetch(STEPS[prev_idx], 0) * 100).round
    end

    def first_appearance?
      step == STEPS.first
    end

    def back_path
      prev_step = previous_step
      return nil if prev_step.nil?
      helpers.public_send("onboarding_#{prev_step}_path", back: 1)
    end

    def going_back?
      helpers.params[:back].to_s == "1"
    end

    private

    def previous_step
      idx = STEPS.index(step)
      return nil if idx.nil?
      idx.zero? ? ENTRY_STEP : STEPS[idx - 1]
    end
  end
end
