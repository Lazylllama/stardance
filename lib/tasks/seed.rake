namespace :seed do
  desc "Seed the database with a realistic community for development"
  task community: :environment do
    require_relative "../../db/development_seed/runner"
    DevelopmentSeed::Runner.call
  end
end
