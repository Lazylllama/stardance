require "test_helper"

module Admin
  module MegaDashboard
    class QueueTest < ActiveSupport::TestCase
      setup do
        Flipper.enable(:hardware_flow)
        # Funding requests require a verified, YSWS-eligible owner.
        @owner = ::User.create!(
          slack_id: "U_QUEUE_OWNER", display_name: "queue-owner", email: "queue-owner@example.test",
          verification_status: :verified, ysws_eligible: true
        )
        @mission = ::Mission.create!(
          slug: "hw-queue-#{SecureRandom.hex(3)}", name: "Hardware mission",
          description: "Build something", hardware: true
        )
      end

      teardown { Flipper.disable(:hardware_flow) }

      test "the hardware design queue counts only what its dash can hand out" do
        reviewable = funding_request(hardware_project("design"))
        deleted = funding_request(hardware_project("design"))
        deleted.project.soft_delete!
        on_mission = funding_request(attach_to_mission(hardware_project("design")))

        pending = Queue.find("hardware_design").pending.call

        assert_includes pending, reviewable
        assert_not_includes pending, deleted
        assert_not_includes pending, on_mission
      end

      test "the hardware build queue counts only what its dash can hand out" do
        reviewable = ship(hardware_project("build"))
        deleted = ship(hardware_project("build"))
        deleted.project.soft_delete!
        on_mission = ship(attach_to_mission(hardware_project("build")))

        pending = Queue.find("hardware_build").pending.call

        assert_includes pending, reviewable
        assert_not_includes pending, deleted
        assert_not_includes pending, on_mission
      end

      test "hardware build certifications stay out of the software ship queue" do
        hardware = ship(hardware_project("build"))

        assert_not_includes Queue.find("ship_certifications").pending.call, hardware
      end

      private

      def hardware_project(stage)
        project = ::Project.create!(title: "HW #{SecureRandom.hex(4)}")
        project.memberships.create!(user: @owner, role: :owner)
        project.update!(hardware_stage: stage)
        project
      end

      # Attached before the review is created: attaching a shipped project to a
      # mission is rejected.
      def attach_to_mission(project)
        ::Project::MissionAttachment.create!(project: project, mission: @mission)
        project
      end

      def funding_request(project)
        add_devlog(project)
        project.certification_funding_requests.create!(
          user: @owner, complexity_tier: 2, requested_amount_cents: 4_200, status: :pending
        )
      end

      def ship(project)
        ::Certification::Ship.create!(project: project, status: :pending)
      end

      def add_devlog(project)
        devlog = ::Post::Devlog.new(body: "initial log", duration_seconds: 3600, phase: project.hardware_stage)
        devlog.uploading_attachments = true
        devlog.save!
        ::Post.create!(project: project, user: @owner, postable: devlog)
      end
    end
  end
end
