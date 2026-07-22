class HCBError < StandardError; end
class HCBUnauthorizedError < HCBError; end

# Middleware: raise specific error for 401 so we can refresh + retry,
# and raise generic HCBError for other non-success responses.
class RaiseHCBErrorMiddleware < Faraday::Middleware
  def on_complete(env)
    status = env.status
    body = env.body

    if status == 401
      raise HCBUnauthorizedError, "HCB returned 401: #{body}"
    end

    raise HCBError, "HCB returned #{status}: #{body}" unless env.response.success?
  end
end

Faraday::Response.register_middleware hcb_error: RaiseHCBErrorMiddleware

module HCBService
  class << self
    def base_url
      hcb_credentials = HCBCredential.first
      hcb_credentials&.base_url.presence || "https://hcb.hackclub.com"
    end

    def slug
      hcb_credentials = HCBCredential.first
      hcb_credentials&.slug.presence || "stardance"
    end

    # Generic wrapper that will attempt a token refresh on 401 once, then retry.
    def with_retry
      attempts = 0
      begin
        yield
      rescue HCBUnauthorizedError
        attempts += 1
        if attempts <= 1 && refresh_token!
          retry
        end
        raise
      end
    end

    def refresh_token!
      hcb_credentials = HCBCredential.first
      raise HCBError, "no HCB credentials found" unless hcb_credentials

      # Lock the row before reading the refresh token. HCB refresh tokens are
      # single-use and rotate on every refresh, so if two requests race here,
      # whoever reads the token first (before the winner's update commits)
      # submits an already-consumed token and gets invalid_grant. Locking
      # forces the loser to wait, then `with_lock` reloads the record so it
      # reads the winner's freshly-rotated token instead of a stale one.
      hcb_credentials.with_lock do
        client_id = hcb_credentials.client_id
        client_secret = hcb_credentials.client_secret
        refresh_token = hcb_credentials.refresh_token
        redirect_uri = hcb_credentials.redirect_uri
        base = hcb_credentials.base_url || base_url

        # Use a lightweight connection to call the token endpoint to avoid recursion.
        # Doorkeeper expects a form-encoded POST (application/x-www-form-urlencoded).
        token_conn = Faraday.new(url: "#{base}/api/v4/") do |f|
          f.request :url_encoded
          f.response :json, content_type: /\bjson$/
          f.adapter :net_http
          f.headers["Accept"] = "application/json"
          # Bounded so a hung HCB request can't hold the row lock open indefinitely.
          f.options.open_timeout = 5
          f.options.timeout = 10
        end

        message = {
          client_id: client_id,
          client_secret: client_secret,
          refresh_token: refresh_token,
          redirect_uri: redirect_uri,
          grant_type: "refresh_token"
        }

        # Send form-encoded params (not JSON) so Doorkeeper accepts the refresh request.
        resp = token_conn.post("oauth/token", message)

        unless resp.success?
          error_msg = resp.body.is_a?(Hash) ? resp.body["error"] || resp.body[:error] : resp.body
          raise HCBError, "token refresh failed with status #{resp.status}: #{error_msg}"
        end

        body = resp.body
        access_token = body && (body["access_token"] || body[:access_token])
        new_refresh_token = body && (body["refresh_token"] || body[:refresh_token])
        raise HCBError, "no access_token in response: #{body}" unless access_token

        # HCB has already rotated the refresh token server-side at this point —
        # the old one is dead regardless of what happens next. Retry the local
        # save a few times so a transient DB blip doesn't strand us holding
        # valid tokens we never wrote down.
        persisted = false
        persist_error = nil
        3.times do |attempt|
          hcb_credentials.update!(refresh_token: new_refresh_token, access_token: access_token)
          persisted = true
          break
        rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
          # Only retry on transient DB/connection errors. Validation errors
          # (ActiveRecord::RecordInvalid) are deterministic, so let them raise
          # immediately instead of retrying a failure that can't change.
          persist_error = e
          sleep(0.2 * (attempt + 1)) if attempt < 2
        end

        unless persisted
          Sentry.capture_message(
            "HCB token refresh succeeded but failed to persist new tokens - credentials are now bricked",
            level: :fatal,
            extra: { error: persist_error&.message }
          )
          raise HCBError, "refreshed HCB tokens but failed to save them: #{persist_error&.message}"
        end

        @conn = nil

        true
      end
    rescue Faraday::Error => e
      raise HCBError, "token refresh HTTP error: #{e.message}"
    rescue HCBError
      raise
    rescue => e
      raise HCBError, "token refresh failed: #{e.message}"
    end

    def create_card_grant(email:, amount_cents:, merchant_lock: nil, category_lock: nil, keyword_lock: nil, purpose: nil, pre_authorization_required: false, one_time_use: false, instructions: nil, organization: nil)
      with_retry do
        org = organization || @hcb_org_slug
        conn.post("organizations/#{org}/card_grants", email:, amount_cents:, category_lock:, merchant_lock:, keyword_lock:, purpose:, pre_authorization_required:, one_time_use:, instructions:).body
      end
    end

    def topup_card_grant(hashid:, amount_cents:)
      Rails.logger.info "Topping up HCB card grant #{hashid} by #{amount_cents}¢"
      with_retry { conn.post("card_grants/#{hashid}/topup", amount_cents:).body }
    end

    def rename_transaction(hashid:, new_memo:)
      with_retry { conn.put("organizations/#{@hcb_org_slug}/transactions/#{hashid}", memo: new_memo).body }
    end

    def show_card_grant(hashid:)
      with_retry { conn.get("card_grants/#{hashid}?expand=balance_cents,disbursements").body }
    end

    def update_card_grant(hashid:, merchant_lock: nil, category_lock: nil, keyword_lock: nil, purpose: nil, instructions: nil)
      with_retry { conn.patch("card_grants/#{hashid}", { merchant_lock:, category_lock:, keyword_lock:, purpose:, instructions: }.compact).body }
    end

    def show_stripe_card(hashid:)
      with_retry { conn.get("cards/#{hashid}").body }
    end

    def cancel_card_grant!(hashid:)
      with_retry { conn.post("card_grants/#{hashid}/cancel").body }
    end

    def index_card_grants
      with_retry { conn.get("organizations/#{@hcb_org_slug}/card_grants").body }
    end

    # Builds (or returns cached) Faraday connection for HCB API.
    # Uses Bearer token from HCBCredential for OAuth authentication.
    def conn
      hcb_creds = HCBCredential.first
      raise HCBError, "no HCB credentials found" unless hcb_creds
      hcb_access_token = hcb_creds.access_token
      @hcb_org_slug = hcb_creds.slug

      @conn ||= Faraday.new url: "#{hcb_creds.base_url || base_url}/api/v4/" do |faraday|
        faraday.request :json
        faraday.response :mashify
        faraday.response :json
        faraday.response :hcb_error
        faraday.headers["Authorization"] = "Bearer #{hcb_access_token}"
      end
    end
  end
end
