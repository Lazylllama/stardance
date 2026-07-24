require "test_helper"

# Forces app/services/hcb_service.rb to autoload now, since Zeitwerk only
# indexes the file under its matching constant (HCBService) — the bare
# HCBError class defined alongside it in the same file wouldn't otherwise be
# defined yet if a test referencing it runs before anything touches HCBService.
HCBService

class HCBServiceTest < ActiveSupport::TestCase
  class FakeFaradayConn
    def options
      @options ||= OpenStruct.new
    end

    def request(*); end
    def response(*); end
    def adapter(*); end

    def headers
      @headers ||= {}
    end

    def post(*)
      OpenStruct.new(success?: true, body: { "access_token" => "new-access-token", "refresh_token" => "new-refresh-token" })
    end
  end

  setup do
    HCBCredential.delete_all
    @creds = HCBCredential.create!(
      client_id: "demo-client",
      client_secret: "demo-secret",
      refresh_token: "old-refresh-token",
      access_token: "old-access-token",
      base_url: "https://hcb.hackclub.com",
      redirect_uri: "https://example.com/callback"
    )
    @fake_faraday_new = lambda do |*_args, **_kwargs, &blk|
      conn = FakeFaradayConn.new
      blk.call(conn) if blk
      conn
    end
  end

  # Temporarily replaces an instance method on `klass`, then restores the
  # original. Used to force ActiveRecord::StatementInvalid from `update!`
  # without needing a real DB outage.
  def replace_method(klass, method_name, replacement)
    original = klass.instance_method(method_name)
    klass.send(:define_method, method_name) do |*args, **kwargs, &blk|
      replacement.call(self, *args, **kwargs, &blk)
    end
    yield
  ensure
    klass.send(:define_method, method_name, original)
  end

  test "refresh_token! retries a transient save failure and succeeds without alerting Sentry" do
    real_update_bang = HCBCredential.instance_method(:update!)
    attempts = 0
    fail_once_then_succeed = lambda do |instance, *args, **kwargs|
      attempts += 1
      raise ActiveRecord::StatementInvalid, "simulated transient blip" if attempts == 1
      real_update_bang.bind(instance).call(*args, **kwargs)
    end

    sentry_calls = 0
    Sentry.stub(:capture_message, ->(*) { sentry_calls += 1 }) do
      Faraday.stub(:new, @fake_faraday_new) do
        replace_method(HCBCredential, :update!, fail_once_then_succeed) do
          assert HCBService.refresh_token!
        end
      end
    end

    assert_equal 2, attempts, "expected exactly one retry before success"
    assert_equal 0, sentry_calls, "a recovered retry should not page anyone"
    assert_equal "new-access-token", @creds.reload.access_token
  end

  test "refresh_token! gives up after 3 failed saves, alerts Sentry, and preserves the old tokens" do
    attempts = 0
    always_fail = lambda do |_instance, *_args, **_kwargs|
      attempts += 1
      raise ActiveRecord::StatementInvalid, "simulated persistent DB outage"
    end

    sentry_calls = 0
    Sentry.stub(:capture_message, ->(*) { sentry_calls += 1 }) do
      Faraday.stub(:new, @fake_faraday_new) do
        replace_method(HCBCredential, :update!, always_fail) do
          error = assert_raises(HCBError) { HCBService.refresh_token! }
          assert_match(/failed to save/, error.message)
        end
      end
    end

    assert_equal 3, attempts, "expected exactly 3 attempts, no more and no less"
    assert_equal 1, sentry_calls, "an exhausted retry must page someone"
    assert_equal "old-access-token", @creds.reload.access_token, "credentials must not be left half-updated"
  end
end
