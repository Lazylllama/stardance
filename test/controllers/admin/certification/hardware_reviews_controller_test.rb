require "test_helper"

class Admin::Certification::HardwareReviewsControllerTest < ActionDispatch::IntegrationTest
  # Approving a funding request issues a real HCB card grant.
  HCB_GRANT_RESPONSE = { "id" => "test_grant_hwq" }.freeze

  setup do
    Flipper.enable(:hardware_flow)

    @reviewer = create_user(slack_id: "U_HWQ_REV", display_name: "hwq-reviewer")
    @reviewer.grant_role!(:admin)

    @owner = create_user(slack_id: "U_HWQ_OWNER", display_name: "hwq-owner")

    @design_project = hardware_project("Design bot", "design")
    # A funding request requires the project to have at least one devlog.
    add_devlog(@design_project)
    @funding = @design_project.certification_funding_requests.create!(
      user: @owner, complexity_tier: 2, requested_amount_cents: 4_200, status: :pending
    )

    @build_project = hardware_project("Build bot", "build")
    @ship = ::Certification::Ship.create!(project: @build_project, status: :pending)

    sign_in @reviewer
  end

  teardown { Flipper.disable(:hardware_flow) }

  test "the design queue lists only funding requests" do
    get design_admin_certification_hardware_reviews_path

    assert_response :success
    assert_select "h1", text: /Design review queue/
    assert_select ".ship-queue__project-title", text: /Design bot/
    assert_select ".ship-queue__project-title", text: /Build bot/, count: 0
  end

  test "the build queue lists only ship certifications" do
    get build_admin_certification_hardware_reviews_path

    assert_response :success
    assert_select "h1", text: /Build review queue/
    assert_select ".ship-queue__project-title", text: /Build bot/
    assert_select ".ship-queue__project-title", text: /Design bot/, count: 0
  end

  test "each queue counts only its own stage as waiting" do
    get design_admin_certification_hardware_reviews_path
    assert_select ".hardware-queue__vital--primary .hardware-queue__vital-value", text: "1"

    get build_admin_certification_hardware_reviews_path
    assert_select ".hardware-queue__vital--primary .hardware-queue__vital-value", text: "1"
  end

  test "the design queue shows the requested amount, the build queue shows hours" do
    get design_admin_certification_hardware_reviews_path
    assert_select ".hardware-queue__ask", text: "$42"

    get build_admin_certification_hardware_reviews_path
    assert_select ".hardware-queue__ask"
  end

  test "both queues are reachable from either one" do
    get design_admin_certification_hardware_reviews_path

    assert_response :success
    assert_select "a[href=?]", design_admin_certification_hardware_reviews_path
    assert_select "a[href=?]", build_admin_certification_hardware_reviews_path
  end

  test "the old combined queue url redirects to the design queue" do
    get admin_certification_hardware_reviews_path

    assert_redirected_to design_admin_certification_hardware_reviews_path
  end

  test "start reviewing stays within the queue it was started from" do
    get design_admin_certification_hardware_reviews_path

    assert_select "a[href=?]", next_admin_certification_hardware_reviews_path(stage: "design")
  end

  test "next on the build queue never hands back a design review" do
    get next_admin_certification_hardware_reviews_path(stage: "build")

    assert_redirected_to admin_certification_hardware_review_path(@build_project)
  end

  test "the design review page leads with the ask and the verdict form" do
    get admin_certification_hardware_review_path(@design_project)

    assert_response :success
    # The number the verdict turns on is a headline fact, not buried in a list.
    assert_select ".hardware-review__fact--primary dt", text: "Requested"
    assert_select ".hardware-review__fact--primary dd", text: "$42"
    assert_select ".hardware-review__tag", text: "Design funding"
    # Supporting context is present but folded away.
    assert_select "details.hardware-review__more .hardware-review__timeline"
  end

  test "the build review page leads with the effort instead of the ask" do
    get admin_certification_hardware_review_path(@build_project)

    assert_response :success
    assert_select ".hardware-review__fact--primary dt", text: "Hours logged"
    assert_select ".hardware-review__tag", text: "Build certification"
    assert_select ".hardware-review__fact--primary dt", text: "Requested", count: 0
  end

  test "the review page links back to its own queue" do
    get admin_certification_hardware_review_path(@design_project)
    assert_select "a[href=?]", design_admin_certification_hardware_reviews_path

    get admin_certification_hardware_review_path(@build_project)
    assert_select "a[href=?]", build_admin_certification_hardware_reviews_path
  end

  test "the review page offers the evidence links a reviewer opens" do
    @design_project.update_columns(repo_url: "https://github.com/x/y", demo_url: "https://example.com/demo")

    get admin_certification_hardware_review_path(@design_project)

    assert_select ".hardware-review__link", text: /Repo/
    assert_select ".hardware-review__link", text: /Demo/
    assert_select ".hardware-review__link", text: /Project page/
  end

  test "the queue carries a hardware-scoped my-stats modal" do
    get design_admin_certification_hardware_reviews_path

    assert_response :success
    assert_select "dialog#hardware-my-stats"
    # Both queues are represented, which the site-wide stats page can't do.
    assert_select "#hardware-my-stats tbody th", text: "Design"
    assert_select "#hardware-my-stats tbody th", text: "Build"
    assert_select "#hardware-my-stats a[href=?]", admin_certification_mystats_path
  end

  test "my-stats counts the reviewer's own decided hardware reviews" do
    HCBService.stub(:create_card_grant, HCB_GRANT_RESPONSE) do
      @funding.update!(reviewer: @reviewer, status: :approved, feedback: "looks good")
    end

    get design_admin_certification_hardware_reviews_path

    assert_response :success
    # Design row: 1 reviewed, 1 approved, 100% - none of which the ship-only
    # site-wide stats page would show.
    assert_select "#hardware-my-stats tbody tr:first-child td", text: "1", count: 2
    assert_select "#hardware-my-stats tbody tr:first-child td", text: "100%"
  end

  test "my-stats ignores reviews decided by someone else" do
    other = create_user(slack_id: "U_HWQ_OTHER", display_name: "hwq-other")
    other.grant_role!(:admin)
    HCBService.stub(:create_card_grant, HCB_GRANT_RESPONSE) do
      @funding.update!(reviewer: other, status: :approved, feedback: "not mine")
    end

    get design_admin_certification_hardware_reviews_path

    assert_select "#hardware-my-stats tbody tr:first-child td", text: "0", count: 3
  end

  # A reviewer working the queue shouldn't have to go back to the list between
  # verdicts.
  test "submitting a design verdict advances to the next review" do
    ::Certification::FundingRequest.atomic_claim!(@funding.id, @reviewer)
    HCBService.stub(:create_card_grant, HCB_GRANT_RESPONSE) do
      patch admin_certification_funding_request_path(@funding),
            params: { redirect_to_hardware: @design_project.id,
                      certification_funding_request: { verdict: "approved", feedback: "looks good" } }
    end

    assert_redirected_to next_admin_certification_hardware_reviews_path(stage: "design")
  end

  test "a reviewer can approve a design without issuing a grant" do
    ::Certification::FundingRequest.atomic_claim!(@funding.id, @reviewer)

    grant_called = false
    HCBService.stub(:create_card_grant, ->(*) { grant_called = true; HCB_GRANT_RESPONSE }) do
      patch admin_certification_funding_request_path(@funding),
            params: { redirect_to_hardware: @design_project.id,
                      certification_funding_request: { verdict: "approved_without_grant", feedback: "you're covered" } }
    end

    assert_not grant_called
    assert @funding.reload.approved_without_grant?
    assert_nil @funding.hcb_grant_hashid
    assert_equal "build", @design_project.reload.hardware_stage
  end

  test "an emptied design queue lands back on the design queue, not a dead end" do
    ::Certification::FundingRequest.atomic_claim!(@funding.id, @reviewer)
    HCBService.stub(:create_card_grant, HCB_GRANT_RESPONSE) do
      patch admin_certification_funding_request_path(@funding),
            params: { redirect_to_hardware: @design_project.id,
                      certification_funding_request: { verdict: "approved", feedback: "looks good" } }
    end
    follow_redirect!

    assert_redirected_to design_admin_certification_hardware_reviews_path
  end

  # The verdict form partial used to render its own unclaim button on top of the
  # page's, so a claimed design review showed two.
  test "a claimed design review shows exactly one unclaim button" do
    ::Certification::FundingRequest.atomic_claim!(@funding.id, @reviewer)

    get admin_certification_hardware_review_path(@design_project)

    assert_response :success
    assert_select "button[form=?]", "unclaim-form-#{@funding.id}", count: 1
  end

  test "a claimed build review shows exactly one unclaim button" do
    ::Certification::Ship.atomic_claim!(@ship.id, @reviewer)

    get admin_certification_hardware_review_path(@build_project)

    assert_response :success
    assert_select "button[form=?]", "unclaim-form-#{@ship.id}", count: 1
  end

  test "non-reviewers can't reach either queue" do
    sign_in @owner

    get design_admin_certification_hardware_reviews_path
    assert_response :forbidden

    get build_admin_certification_hardware_reviews_path
    assert_response :forbidden
  end

  private

  def add_devlog(project)
    devlog = Post::Devlog.new(body: "initial log", duration_seconds: 3600, phase: project.hardware_stage)
    devlog.uploading_attachments = true
    devlog.save!
    Post.create!(project: project, user: @owner, postable: devlog)
  end

  def hardware_project(title, stage)
    project = Project.create!(title: title)
    project.memberships.create!(user: @owner, role: :owner)
    project.update!(hardware_stage: stage)
    project
  end
end
