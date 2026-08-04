require "test_helper"

class HardwareKitRedemptionTest < ActionDispatch::IntegrationTest
  PIXEL_PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")

  setup do
    @owner = User.create!(email: "owner-#{SecureRandom.hex(6)}@example.com",
                          display_name: "Owner#{SecureRandom.hex(3)}", slack_id: "U#{SecureRandom.hex(8)}")
    @stranger = User.create!(email: "str-#{SecureRandom.hex(6)}@example.com",
                             display_name: "Str#{SecureRandom.hex(3)}", slack_id: "U#{SecureRandom.hex(8)}")
    @project = Project.create!(title: "HW #{SecureRandom.hex(4)}", hardware_stage: "design")
    Project::Membership.create!(project: @project, user: @owner, role: :owner)
    @mission = create_mission
    @mission.update!(hardware: true)
    @project.mission_attachments.create!(mission: @mission)

    devlog = Post::Devlog.new(body: "log", duration_seconds: 3600, phase: "design")
    devlog.uploading_attachments = true
    devlog.save!
    Post.create!(project: @project, user: @owner, postable: devlog)

    @kit = ShopItem.new(name: "Hackpad Kit #{SecureRandom.hex(3)}", description: "the kit", ticket_cost: 0,
                        type: "ShopItem::ThirdPartyPhysical", enabled: true, mission_prize_only: true)
    @kit.image.attach(io: StringIO.new(PIXEL_PNG), filename: "kit.png", content_type: "image/png")
    @kit.save!
    @mission.prizes.create!(shop_item: @kit, position: 0, category: :after_design)

    @funding_request = @project.certification_funding_requests.create!(user: @owner, status: :pending)
    @funding_request.update!(status: :approved)
  end

  test "the kit page renders a redeem form for the approved request owner" do
    sign_in @owner
    get shop_item_path(@kit, funding_request_id: @funding_request.id)
    assert_response :success
    assert_select "input[name=?][value=?]", "funding_request_id", @funding_request.id.to_s
  end

  test "the kit is not redeemable by a non-owner" do
    sign_in @stranger
    get shop_item_path(@kit, funding_request_id: @funding_request.id)
    assert_redirected_to shop_path
  end

  test "the kit is not redeemable without an approved request" do
    @funding_request.update!(status: :returned, feedback: "nope")
    sign_in @owner
    get shop_item_path(@kit, funding_request_id: @funding_request.id)
    assert_redirected_to shop_path
  end
end
