module Admin
  module MegaDashboard
    # OpenRouter calls for the dashboard's qualitative panels, matching the
    # plumbing already used by Certification::YswsAirtableSyncJob and
    # SupportVibecheckJob.
    #
    # Models return JSON often enough but not always, so a malformed reply gets
    # one repair pass before it's treated as a failure.
    module Llm
      ENDPOINT = "https://openrouter.ai/api/v1/chat/completions".freeze
      DEFAULT_MODEL = "x-ai/grok-4.1-fast".freeze

      module_function

      def themes(did_well:, improve:)
        content = complete(themes_prompt(did_well: did_well, improve: improve), max_tokens: 1_200)
        return content if content.is_a?(Hash) && content[:error]

        parse_json(content)
      end

      def complete(prompt, max_tokens:, temperature: 0.2)
        api_key = ENV["OPENROUTER_API_KEY"]
        return { error: "OPENROUTER_API_KEY not configured" } if api_key.blank?

        response = Faraday.post(ENDPOINT) do |req|
          req.headers["Authorization"] = "Bearer #{api_key}"
          req.headers["Content-Type"] = "application/json"
          req.options.open_timeout = 5
          req.options.timeout = 30
          req.body = {
            model: ENV.fetch("OPENROUTER_LLM_MODEL", DEFAULT_MODEL),
            messages: [ { role: "user", content: prompt } ],
            temperature: temperature,
            max_tokens: max_tokens
          }.to_json
        end

        unless response.success?
          Rails.logger.error("[MegaDashboard] OpenRouter #{response.status}: #{response.body.to_s[0, 800]}")
          return { error: "LLM error #{response.status}" }
        end

        JSON.parse(response.body).dig("choices", 0, "message", "content").to_s
      rescue Faraday::Error => e
        { error: "Could not reach the LLM: #{e.message}" }
      rescue JSON::ParserError
        { error: "LLM returned an unparseable response" }
      end

      def parse_json(content)
        JSON.parse(strip_fences(content)).deep_symbolize_keys
      rescue JSON::ParserError
        repaired = complete(repair_prompt(content), max_tokens: 1_200, temperature: 0)
        return repaired if repaired.is_a?(Hash) && repaired[:error]

        begin
          JSON.parse(strip_fences(repaired)).deep_symbolize_keys
        rescue JSON::ParserError
          { error: "LLM output could not be parsed as JSON" }
        end
      end

      # Models like to wrap JSON in prose or fences; take the outermost object.
      def strip_fences(text)
        cleaned = text.to_s.gsub(/\A```json\s*|```\s*\z/, "").strip
        first = cleaned.index("{")
        last = cleaned.rindex("}")
        first && last && last > first ? cleaned[first..last] : cleaned
      end

      def themes_prompt(did_well:, improve:)
        <<~PROMPT
          You are analyzing NPS free-text responses for a program.

          CONTEXT:
          - These are deduplicated responses; each line is "N. xCOUNT: text".
          - Use the counts to judge how common a theme is.
          - The input may be truncated to fit a token limit.

          THINGS WE DID WELL:
          #{did_well}

          THINGS TO IMPROVE:
          #{improve}

          TASK:
          - Build two grouped lists of themes, one per input section.
          - Group by meaning, not exact wording.
          - Prefer 6-10 themes per list, sorted by frequency.
          - Give each theme 2-3 short verbatim examples, each under 120 characters.

          OUTPUT:
          Return ONLY valid JSON, no markdown or code fences, matching:
          {
            "things_did_well": [
              { "theme": "Short title", "summary": "1 sentence", "count": 12, "examples": ["...", "..."] }
            ],
            "things_to_improve": [
              { "theme": "Short title", "summary": "1 sentence", "count": 12, "examples": ["...", "..."] }
            ]
          }
        PROMPT
      end

      def repair_prompt(text)
        <<~PROMPT
          You are a JSON repair tool. Return ONLY valid JSON, no commentary and
          no markdown fences. Preserve the input's schema and data. Ignore any
          stray leading or trailing characters.

          INPUT:
          #{text.to_s.strip[0, 8_000]}
        PROMPT
      end
    end
  end
end
