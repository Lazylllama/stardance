require "test_helper"

class HardwareKitFundingSubmissionTest < ActionDispatch::IntegrationTest
  PIXEL_PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")

  setup do
    Flipper.enable(:hardware_flow)
    @owner = User.create!(email: "owner-#{SecureRandom.hex(6)}@example.com",
                          display_name: "Owner#{SecureRandom.hex(3)}", slack_id: "U#{SecureRandom.hex(8)}")
    @project = Project.create!(title: "HW #{SecureRandom.hex(4)}", hardware_stage: "design")
    Project::Membership.create!(project: @project, user: @owner, role: :owner)
    @mission = create_mission
    @mission.update!(hardware: true)
    @project.mission_attachments.create!(mission: @mission)

    devlog = Post::Devlog.new(body: "log", duration_seconds: 3600, phase: "design")
    devlog.uploading_attachments = true
    devlog.save!
    Post.create!(project: @project, user: @owner, postable: devlog)
  end

  test "kit mission: submitting a design with no tier or amount creates a valid request" do
    add_after_design_kit

    sign_in @owner
    assert_difference -> { @project.certification_funding_requests.count }, 1 do
      post project_funding_request_path(@project)
    end
    assert_redirected_to project_path(@project)

    request = @project.certification_funding_requests.last
    assert request.awards_design_kit?
    assert_equal 0, request.requested_amount_cents
    assert_includes Certification::FundingRequest::TIER_MAX_CENTS.keys, request.complexity_tier
  end

  test "non-kit mission: submitting without a tier or amount is rejected" do
    sign_in @owner
    assert_no_difference -> { @project.certification_funding_requests.count } do
      post project_funding_request_path(@project)
    end
  end

  private

  def add_after_design_kit
    kit = ShopItem.new(name: "Kit #{SecureRandom.hex(3)}", description: "the kit", ticket_cost: 0,
                       type: "ShopItem::ThirdPartyPhysical", enabled: true, mission_prize_only: true)
    kit.image.attach(io: StringIO.new(PIXEL_PNG), filename: "kit.png", content_type: "image/png")
    kit.save!
    @mission.prizes.create!(shop_item: kit, position: 0, category: :after_design)
  end
end
