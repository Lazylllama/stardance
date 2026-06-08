require_relative "config"
require_relative "helpers"
require_relative "users"
require_relative "projects"

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
      projects = DevelopmentSeed::Projects.call(users)
      
      log "Successfully generated #{users.count} users and #{projects.count} projects."
      log "Development community seed complete!"
    end

    private

    def cleanup
      progress "Cleaning up existing community data"
      
      # Protect the admin user if they exist
      admin_email = "kartikey@hackclub.com"
      
      # Destroy users and dependent associations (projects, memberships, posts, etc.)
      # We use destroy_all to ensure callbacks/dependent: :destroy are fired.
      User.where.not(email: admin_email).destroy_all
      
      # In case there are orphaned projects or posts
      Project.where.not(id: Project::Membership.where(user: User.find_by(email: admin_email)).select(:project_id)).destroy_all
      
      done
    end
  end
end
