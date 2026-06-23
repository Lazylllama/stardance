require "rack/attack"

Rack::Attack.cache.store = Rails.cache

Rack::Attack.throttled_responder = lambda do |req|
  match_data = req.env["rack.attack.match_data"]
  period     = match_data[:period]
  epoch_time = match_data[:epoch_time] || Time.now.to_i
  reset_in   = period - (epoch_time % period)
  time_label = reset_in >= 60 ? "#{(reset_in / 60.0).ceil} minutes" : "#{reset_in} seconds"
  message    = "You're doing that too fast. Try again in #{time_label}."

  accept = req.env["HTTP_ACCEPT"].to_s

  if accept.include?("text/vnd.turbo-stream.html")
    turbo_html = <<~HTML
      <turbo-stream action="prepend" target="flash-region">
        <template>
          <div class="flash-container">
            <div class="alert alert-error" role="alert" aria-live="assertive" data-controller="flash" data-flash-timeout-value="5000">
              <div class="alert__content">#{message}</div>
              <button type="button" class="alert__close" aria-label="Close" title="Close" data-action="click->flash#close">&times;</button>
            </div>
          </div>
        </template>
      </turbo-stream>
    HTML

    [ 429, { "Content-Type" => "text/vnd.turbo-stream.html; charset=utf-8", "Retry-After" => reset_in.to_s }, [ turbo_html ] ]

  elsif accept.include?("application/json")
    body = { error: "rate_limited", message: message }.to_json

    [ 429, { "Content-Type" => "application/json", "Retry-After" => reset_in.to_s }, [ body ] ]

  else
    referer = req.env["HTTP_REFERER"] || "/"
    html = <<~HTML
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Too many requests</title>
          <style>
            body { background: #08061E; color: #FFF8D5; font-family: sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
            .box { text-align: center; }
            p { color: #EBB7FF; margin: 0.5rem 0 1.5rem; }
            a { color: #81FFFF; }
          </style>
        </head>
        <body>
          <div class="box">
            <h1>Slow down!</h1>
            <p>#{message}</p>
            <a href="#{referer}">&larr; Go back</a>
          </div>
        </body>
      </html>
    HTML

    [ 429, { "Content-Type" => "text/html; charset=utf-8", "Retry-After" => reset_in.to_s }, [ html ] ]
  end
end

# authenticated user ID via warden, falls back to IP

user_id = ->(req) { req.env["warden"]&.user(:user)&.id&.to_s || req.ip }

Rack::Attack.throttle("user_follows", limit: 10, period: 60) do |req|
  user_id.call(req) if req.post? && req.path.match?(%r{^/users/\d+/follow$})
end

Rack::Attack.throttle("project_follows", limit: 10, period: 60) do |req|
  user_id.call(req) if req.post? && req.path.match?(%r{^/projects/[^/]+/follow$})
end

Rack::Attack.throttle("devlog_likes", limit: 30, period: 60) do |req|
  user_id.call(req) if req.post? && req.path.match?(%r{^/devlogs/\d+/like$})
end

Rack::Attack.throttle("devlog_comments", limit: 5, period: 60) do |req|
  user_id.call(req) if req.post? && req.path.match?(%r{^/devlogs/\d+/comments$})
end

Rack::Attack.throttle("devlog_reposts", limit: 10, period: 60) do |req|
  user_id.call(req) if req.post? && req.path.match?(%r{^/devlogs/\d+/repost$})
end

