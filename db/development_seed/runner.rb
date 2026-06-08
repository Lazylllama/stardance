require_relative "config"
require_relative "helpers"
require_relative "users"

module DevelopmentSeed
  class Runner
    include Helpers
    extend Helpers

    def self.call
      new.call
    end

    def call
      log "Starting development community seed..."
      
      cleanup
      
      users = DevelopmentSeed::Users.call
      
      log "Successfully generated #{users.count} users."
      log "Development community seed complete!"
    end

    private

    def cleanup
      progress "Cleaning up existing community data"
      
      admin_email = "kartikey@hackclub.com"
      
      User.where.not(email: admin_email).destroy_all
      
      Project.where.not(id: Project::Membership.where(user: User.find_by(email: admin_email)).select(:project_id)).destroy_all
      
      done
    end
  end
end
