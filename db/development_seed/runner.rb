require_relative "config"
require_relative "helpers"

module DevelopmentSeed
  class Runner
    include Helpers
    extend Helpers

    def self.call
      new.call
    end

    def call
      log "Starting development seed..."
      log "Development seed framework ready."
    end
  end
end
