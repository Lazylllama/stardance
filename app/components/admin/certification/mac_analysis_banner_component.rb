module Admin
  module Certification
    # Pre-screen summary banner for a YSWS review, shown along the top of the
    # review page (see Onboarding::GuestBannerComponent for the banner pattern).
    # The strip carries the verdict; a details drawer expands in place to the
    # signals and the cached evidence behind it.
    #
    # Flag labels are derived from the report data rather than mapped here on
    # purpose: this repo is public, so the flag taxonomy stays out of it. Only
    # `severity` — a neutral four-level scale — drives presentation.
    class MACAnalysisBannerComponent < ViewComponent::Base
      # Signal keys whose value is a percentage already expressed as 0-100.
      PERCENTAGE_KEY_SUFFIX = "_pct".freeze
      # Long list values are truncated in the drawer so one noisy signal (every
      # user-agent string, say) can't push the rest of the report off-screen.
      LIST_PREVIEW_LIMIT = 12

      def initialize(analysis:)
        @analysis = analysis
      end

      def render?
        analysis.present?
      end

      private

        attr_reader :analysis

        def severity
          analysis.worst_severity
        end

        def banner_classes
          [ "mac-banner", severity && "mac-banner--#{severity}" ].compact.join(" ")
        end

        def chip_classes(flag)
          [ "mac-banner__chip", flag["severity"].presence && "mac-banner__chip--#{flag['severity']}" ]
            .compact.join(" ")
        end

        def flag_label(flag)
          flag["type"].to_s.humanize.presence || "Flag"
        end

        def generated_ago
          return if analysis.generated_at.blank?

          "#{time_ago_in_words(analysis.generated_at)} ago"
        end

        # One signal value, formatted on shape alone. Percent-suffixed keys are
        # the only name-based branch (mirroring the integrity helper), so new
        # signals render sensibly without being enumerated here.
        def format_signal(key, value)
          case value
          when Numeric
            if key.to_s.end_with?(PERCENTAGE_KEY_SUFFIX)
              number_to_percentage(value, precision: 1)
            else
              number_with_delimiter(value)
            end
          when Array
            format_list(value)
          when Hash
            format_list(value.map { |name, inner| "#{name}: #{inner}" })
          when true, false
            value ? "yes" : "no"
          else
            value.to_s
          end
        end

        # A list value as a preview plus an overflow count, so the drawer stays
        # scannable when the analyzer emits hundreds of entries.
        def format_list(values)
          entries = values.map { |entry| entry.is_a?(Hash) ? entry.map { |k, v| "#{k} #{v}" }.join(" ") : entry.to_s }
          preview = entries.first(LIST_PREVIEW_LIMIT)
          overflow = entries.size - preview.size

          items = preview.map { |entry| tag.li(entry, class: "mac-banner__list-item") }
          items << tag.li("+#{overflow} more", class: "mac-banner__list-item mac-banner__list-item--overflow") if overflow.positive?
          tag.ul(safe_join(items), class: "mac-banner__list")
        end

        def format_cell(value)
          case value
          when nil then tag.span("—", class: "mac-banner__placeholder")
          when Numeric then number_with_delimiter(value)
          when true, false then value ? "yes" : "no"
          when Array, Hash then value.to_json
          else value.to_s
          end
        end

        def minutes_delta(recommendation)
          original = recommendation["original_minutes"].to_i
          recommended = recommendation["recommended_minutes"].to_i
          helpers.number_with_sign(recommended - original)
        end

        def format_minutes(minutes)
          return tag.span("—", class: "mac-banner__placeholder") if minutes.blank?

          "#{number_with_delimiter(minutes.to_i)} min (#{helpers.format_minutes_as_time(minutes.to_i)})"
        end
    end
  end
end
