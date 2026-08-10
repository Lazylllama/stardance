require "test_helper"

class Projects::FundingRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Flipper.enable(:hardware_flow)

    @owner = create_user(slack_id: "U_FRC_OWNER", display_name: "frc-owner")
    @project = Project.create!(title: "Funding bot")
    @project.memberships.create!(user: @owner, role: :owner)
    @project.update!(hardware_stage: "design")
    add_devlog(@project)

    sign_in @owner
  end

  teardown { Flipper.disable(:hardware_flow) }

  # Vote debt is the price of shipping (Post::ShipEvent::VOTE_COST_PER_SHIP).
  # Asking for funding is not shipping - the builder hasn't produced anything for
  # anyone to rate yet - so it must not touch the balance.
  test "requesting funding does not put the owner into vote debt" do
    assert_difference -> { @project.certification_funding_requests.count }, 1 do
      assert_no_difference -> { @owner.reload.vote_balance } do
        post project_funding_request_path(@project),
             params: { complexity_tier: 2, requested_amount: 40 }
      end
    end

    assert_redirected_to project_path(@project)
    assert_equal 0, @owner.reload.vote_balance
  end

  test "requesting funding creates no ship event" do
    assert_no_difference -> { Post::ShipEvent.count } do
      post project_funding_request_path(@project),
           params: { complexity_tier: 2, requested_amount: 40 }
    end
  end

  # The balance only moves when they actually ship the finished build.
  test "shipping the build afterwards still charges the usual vote cost" do
    post project_funding_request_path(@project),
         params: { complexity_tier: 2, requested_amount: 40 }
    assert_equal 0, @owner.reload.vote_balance

    @project.update!(hardware_stage: "build")
    # Mirrors Projects::ShipsController#create: both rows are written inside one
    # transaction, so the ship event's after_commit sees its Post.
    ActiveRecord::Base.transaction do
      ship_event = Post::ShipEvent.new(body: "shipped it", uploading_attachments: true)
      ship_event.save!(validate: false)
      Post.create!(project: @project, user: @owner, postable: ship_event)
    end

    assert_equal(-Post::ShipEvent::VOTE_COST_PER_SHIP, @owner.reload.vote_balance)
  end

  # A builder already in debt from a previous ship can still ask for funding;
  # the debt gate belongs to shipping, not to funding.
  test "an owner already in vote debt can still request funding" do
    @owner.update!(vote_balance: -5)

    assert_difference -> { @project.certification_funding_requests.count }, 1 do
      post project_funding_request_path(@project),
           params: { complexity_tier: 2, requested_amount: 40 }
    end

    assert_equal(-5, @owner.reload.vote_balance)
  end

  # --- timeline card ---------------------------------------------------------

  test "the owner sees the funding request on the project timeline" do
    @project.certification_funding_requests.create!(
      user: @owner, complexity_tier: 2, requested_amount_cents: 4_000, status: :pending
    )

    get project_path(@project)

    assert_response :success
    assert_select ".funding-request-card"
    assert_select ".funding-request-card__amount", text: /\$40/
  end

  # The amount asked for is the team's business, not public.
  test "a non-member never sees the funding request" do
    @project.certification_funding_requests.create!(
      user: @owner, complexity_tier: 2, requested_amount_cents: 4_000, status: :pending
    )
    outsider = create_user(slack_id: "U_FRC_OUT", display_name: "frc-out")
    sign_in outsider

    get project_path(@project)

    assert_response :success
    assert_select ".funding-request-card", count: 0
  end

  test "feedback shows on the owner's timeline once decided" do
    returned_request(feedback: "Add a bill of materials")

    get project_path(@project)

    assert_select ".funding-request-card--returned"
    assert_select ".funding-request-card__message", text: /bill of materials/
    assert_select ".funding-request-card .help-badge"
  end

  test "a returned request offers the owner a resubmit button" do
    returned_request(feedback: "Add a bill of materials")

    get project_path(@project)

    assert_select ".funding-request-card__actions button", text: /Submit design again/
  end

  test "an approved request shows no resubmit button" do
    HCBService.stub(:create_card_grant, { "id" => "g1" }) do
      @project.certification_funding_requests.create!(
        user: @owner, complexity_tier: 2, requested_amount_cents: 4_000, status: :pending
      ).update!(reviewer: reviewer, status: :approved, feedback: "great design")
    end

    get project_path(@project)

    assert_select ".funding-request-card--approved"
    assert_select ".funding-request-card__actions button", count: 0
  end

  # A pending request has nothing decided to explain yet, so the standing copy
  # stays in the body instead of collapsing into the tooltip.
  test "a pending request shows the standing message and no help tooltip" do
    @project.certification_funding_requests.create!(
      user: @owner, complexity_tier: 2, requested_amount_cents: 4_000, status: :pending
    )

    get project_path(@project)

    assert_select ".funding-request-card__message", text: /Waiting on a reviewer/
    assert_select ".funding-request-card .help-badge", count: 0
  end

  private

  def reviewer
    @reviewer ||= begin
      user = create_user(slack_id: "U_FRC_REV", display_name: "frc-rev")
      user.grant_role!(:admin)
      user
    end
  end

  def returned_request(feedback:)
    @project.certification_funding_requests.create!(
      user: @owner, complexity_tier: 2, requested_amount_cents: 4_000, status: :pending
    ).update!(reviewer: reviewer, status: :returned, feedback: feedback)
  end

  def add_devlog(project)
    devlog = Post::Devlog.new(body: "design log", duration_seconds: 3600, phase: project.hardware_stage)
    devlog.uploading_attachments = true
    devlog.save!
    Post.create!(project: project, user: @owner, postable: devlog)
  end
end
