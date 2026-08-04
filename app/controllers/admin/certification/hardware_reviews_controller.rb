# frozen_string_literal: true

# Hardware review queues and project page. Design funding and build
# certification are genuinely different jobs, with different evidence and a
# different decision, so they get one queue each rather than a merged list with
# a type column. Mutations still go through the existing funding/ship endpoints
# so PaperTrail remains attached to the underlying record.
class Admin::Certification::HardwareReviewsController < Admin::Certification::ApplicationController
  before_action -> { head :not_found unless Flipper.enabled?(:hardware_flow, current_user) }
  before_action :set_project, only: [ :show ]
  before_action -> { head :not_found unless @project.hardware? }, only: [ :show ]
  before_action :set_body_class

  # GET /admin/certification/hardware
  # Kept so older links land somewhere sensible.
  def index
    authorize Project, policy_class: Admin::Certification::HardwareReviewPolicy
    # Only the queue's own filters carry over; splatting raw query params would
    # let reserved url_for keys (host, script_name, ...) retarget the redirect.
    redirect_to design_admin_certification_hardware_reviews_path(
      params.permit(:status, :sort, :search, :from, :to, :lb).to_h.compact_blank
    )
  end

  # GET /admin/certification/hardware/design
  def design
    authorize Project, policy_class: Admin::Certification::HardwareReviewPolicy
    load_queue(:design)
    render :queue
  end

  # GET /admin/certification/hardware/build
  def build
    authorize Project, policy_class: Admin::Certification::HardwareReviewPolicy
    load_queue(:build)
    render :queue
  end

  # GET /admin/certification/hardware/next?stage=design|build
  # Stays within the queue the reviewer started from, so "Start reviewing" on the
  # design queue never hands them a build certification.
  def next
    authorize Project, policy_class: Admin::Certification::HardwareReviewPolicy

    stage = params[:stage].presence_in(%w[design build]) || "design"
    skip = parse_skip_tokens
    candidate = next_candidate(skip, stage)
    if candidate.nil?
      redirect_to queue_path_for(stage), notice: "#{stage.capitalize} queue is empty." and return
    end

    claimed = claim_candidate(candidate)
    if claimed
      redirect_to admin_certification_hardware_review_path(claimed.project_id)
    else
      redirect_to next_admin_certification_hardware_reviews_path(
        stage: stage, skip: (skip[:tokens] + [ candidate[:token] ]).join(",")
      )
    end
  end

  # GET /admin/certification/hardware/:project_id
  def show
    authorize @project, policy_class: Admin::Certification::HardwareReviewPolicy

    load_review_context
  end

  private

  # One stage's queue: its own rows, its own counts. Nothing about the other
  # stage leaks in except the tab count, so the two read as separate queues.
  def load_queue(stage)
    @stage = stage.to_s
    @status = params[:status].presence_in(%w[pending approved returned all]) || "pending"
    @sort = params[:sort] == "newest" ? "newest" : "oldest"
    @search = params[:search].to_s.strip
    @from = parse_date(params[:from])
    @to = parse_date(params[:to])
    @lb_period = params[:lb].presence_in(%w[daily weekly alltime]) || "daily"

    @review_items = sort_review_items(queue_items(@stage))
    @hackpad_project_ids = hackpad_project_ids(@review_items.map { |item| item[:project].id })
    @stats = stage_stats(@stage)
    @tab_counts = {
      "design" => stage_list_scope("design").pending.count,
      "build" => stage_list_scope("build").pending.count
    }
    @leaderboards = {
      "daily" => hardware_leaderboard(:daily),
      "weekly" => hardware_leaderboard(:weekly),
      "alltime" => hardware_leaderboard(:alltime)
    }
    @my_stats = my_hardware_stats
  end

  # The reviewer's own numbers, scoped to hardware. The site-wide My Stats page
  # counts Certification::Ship only, so a design reviewer shows up there as
  # having done nothing even though their payout balance includes the work.
  def my_hardware_stats
    hardware = Project.where.not(hardware_stage: nil)
    design = ::Certification::FundingRequest.where(reviewer: current_user, project: hardware).where.not(status: :pending)
    build = ::Certification::Ship.where(reviewer: current_user, project: hardware).where.not(status: :pending)
    today = Time.current.beginning_of_day

    {
      design: decision_tally(design),
      build: decision_tally(build),
      stardust: design.sum(:stardust_earned).to_f + build.sum(:stardust_earned).to_f,
      today: design.where(decided_at: today..).count + build.where(decided_at: today..).count
    }
  end

  def decision_tally(scope)
    by_status = scope.group(:status).count
    approved = by_status["approved"].to_i
    returned = by_status["returned"].to_i
    total = approved + returned

    {
      total: total,
      approved: approved,
      returned: returned,
      approval_rate: total.zero? ? nil : (approved * 100.0 / total).round
    }
  end

  def stage_model(stage)
    stage.to_s == "design" ? ::Certification::FundingRequest : ::Certification::Ship
  end

  def stage_list_scope(stage)
    stage.to_s == "design" ? hardware_funding_list_scope : hardware_ship_list_scope
  end

  def queue_items(stage)
    scope = apply_queue_filters(stage_list_scope(stage), stage_model(stage))

    if stage == "design"
      scope.includes(:reviewer, project: { memberships: :user }).map do |request|
        review_item(:funding, request, request.project, request.owner, request.created_at)
      end
    else
      scope.includes(:reviewer, :post_ship_event, project: { memberships: :user }).map do |ship|
        review_item(:ship, ship, ship.project, ship.owner, ship.created_at)
      end
    end
  end

  def set_project
    @project = Project.find(params[:project_id])
  end

  def review_owner
    @review_owner ||= @project.memberships.owner.first&.user
  end

  def load_review_context
    @funding_request = @project.latest_funding_request
    @ship = @project.ship_reviews.order(created_at: :desc).first
    @owner = review_owner
    @active_review =
      if @funding_request&.pending?
        @funding_request
      elsif @ship&.pending?
        @ship
      end
    @active_review_type =
      case @active_review
      when ::Certification::FundingRequest then :funding
      when ::Certification::Ship then :ship
      end
    @past_reviews = past_reviews
    @lapse_timelapses = lapse_timelapses_for_review
    @lookout_recordings = lookout_recordings_for_review
  end

  # Every decided funding request and ship for this project, newest first, so a
  # reviewer sees the full history and any prior feedback under "More context".
  # The active (pending) review is left out - it's the thing being decided.
  def past_reviews
    reviews = @project.certification_funding_requests.includes(:reviewer).to_a +
              @project.ship_reviews.includes(:reviewer).to_a
    reviews
      .reject { |review| review.pending? || review == @active_review }
      .sort_by(&:created_at)
      .reverse
  end

  def hardware_funding_scope
    ::Certification::FundingRequest.available_for(current_user)
      .joins(:project)
      .where.not(projects: { hardware_stage: nil })
  end

  def hardware_ship_scope
    ::Certification::Ship.available_for(current_user)
      .joins(:project)
      .where.not(projects: { hardware_stage: nil })
  end

  def hardware_funding_list_scope
    ::Certification::FundingRequest.for_reviewer(current_user)
      .joins(:project)
      .where.not(projects: { hardware_stage: nil })
  end

  def hardware_ship_list_scope
    ::Certification::Ship.for_reviewer(current_user)
      .joins(:project)
      .where.not(projects: { hardware_stage: nil })
  end

  def review_item(type, record, project, owner, submitted_at)
    {
      type: type,
      stage: type == :funding ? "design" : "build",
      stage_label: type == :funding ? "Design" : "Build",
      record: record,
      project: project,
      owner: owner,
      submitted_at: submitted_at,
      token: "#{type}:#{record.id}"
    }
  end

  # Of the given project ids, those whose active mission is Hackpad — so the
  # queue can flag them with a pill without an N+1 of Project#current_mission
  # per row. Returns a Set for O(1) lookup in the view.
  def hackpad_project_ids(project_ids)
    return Set.new if project_ids.empty?

    Project::MissionAttachment.active
      .joins(:mission)
      .where(missions: { slug: "hackpad" }, project_id: project_ids)
      .pluck(:project_id)
      .to_set
  end

  # Only what a reviewer working this queue can act on: how much is waiting, how
  # stale the worst of it is, and whether today is keeping up with intake.
  def stage_stats(stage)
    scope = stage_list_scope(stage)
    model = stage_model(stage)
    sla_days = model::SLA_DAYS
    today = Time.current.beginning_of_day
    oldest = scope.pending.order(:created_at).first

    {
      pending: scope.pending.count,
      oldest_pending: oldest && review_item(
        stage == "design" ? :funding : :ship, oldest, oldest.project, oldest.owner, oldest.created_at
      ),
      overdue_pending: scope.pending.where("#{model.table_name}.created_at < ?", Time.current - sla_days.days).count,
      sla_days: sla_days,
      decisions_today: scope.where.not(status: :pending).where(decided_at: today..).count,
      new_today: scope.where(created_at: today..).count
    }
  end

  def apply_queue_filters(scope, model)
    scope = scope.where(status: @status) unless @status == "all"
    scope = scope.where("#{model.table_name}.created_at >= ?", @from.beginning_of_day) if @from
    scope = scope.where("#{model.table_name}.created_at <= ?", @to.end_of_day) if @to
    return scope if @search.blank?

    if @search.match?(/\A\d+\z/)
      scope.where("#{model.table_name}.id = :id OR projects.title ILIKE :q",
                  id: @search.to_i, q: "%#{@search}%")
    else
      scope.where("projects.title ILIKE ?", "%#{@search}%")
    end
  end

  def sort_review_items(items)
    sorted = items.sort_by { |item| item[:submitted_at] || Time.zone.at(0) }
    @sort == "newest" ? sorted.reverse : sorted
  end

  def hardware_leaderboard(period, now: Time.current, limit: 10)
    rows = Hash.new(0)
    [ ::Certification::FundingRequest, ::Certification::Ship ].each do |model|
      scope = model.joins(:reviewer)
        .where.not(reviewer_id: nil)
        .where.not(status: :pending)
        .where(project_id: Project.where.not(hardware_stage: nil))
      case period.to_sym
      when :daily then scope = scope.where(decided_at: now.beginning_of_day..)
      when :weekly then scope = scope.where(decided_at: now.beginning_of_week..)
      end
      scope.group("users.display_name").count.each do |name, count|
        rows[name] += count
      end
    end
    rows.sort_by { |name, count| [ -count, name ] }.first(limit).map { |name, count| { name: name, count: count } }
  end

  def parse_date(value)
    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def parse_skip_tokens
    tokens = params[:skip].to_s.split(",").map(&:strip).reject(&:blank?).uniq
    {
      tokens: tokens,
      funding_ids: tokens.filter_map { |token| token.delete_prefix("funding:").to_i if token.start_with?("funding:") },
      ship_ids: tokens.filter_map { |token| token.delete_prefix("ship:").to_i if token.start_with?("ship:") }
    }
  end

  def next_candidate(skip, stage)
    if stage == "design"
      scope = hardware_funding_scope
      scope = scope.where.not(id: skip[:funding_ids]) if skip[:funding_ids].any?
      record = scope.order(claim_order_sql(::Certification::FundingRequest), :created_at).first
      record && review_item(:funding, record, record.project, record.owner, record.created_at)
    else
      scope = hardware_ship_scope
      scope = scope.where.not(id: skip[:ship_ids]) if skip[:ship_ids].any?
      record = scope.order(claim_order_sql(::Certification::Ship), :created_at).first
      record && review_item(:ship, record, record.project, record.owner, record.created_at)
    end
  end

  def queue_path_for(stage)
    stage == "build" ? build_admin_certification_hardware_reviews_path : design_admin_certification_hardware_reviews_path
  end
  helper_method :queue_path_for

  def claim_candidate(candidate)
    case candidate[:type]
    when :funding
      ::Certification::FundingRequest.atomic_claim!(candidate[:record].id, current_user)
    when :ship
      ::Certification::Ship.atomic_claim!(candidate[:record].id, current_user)
    end
  end

  def claim_order_sql(model)
    Arel.sql(model.sanitize_sql_array([ "CASE WHEN reviewer_id = ? THEN 0 ELSE 1 END", current_user.id ]))
  end

  # Provider URLs expire after ~1h, so a short cache keyed by project kills the
  # per-render HTTP fan-out without staling them.
  RECORDINGS_CACHE_TTL = 1.minute

  def lapse_timelapses_for_review
    Rails.cache.fetch([ "hardware_review_recordings", "lapse", @project.id ], expires_in: RECORDINGS_CACHE_TTL) do
      LapseService.timelapses_for_project(
        hackatime_user_id: review_owner&.hackatime_identity&.uid,
        project_keys: @project.hackatime_keys
      )
    end
  end

  def lookout_recordings_for_review
    Rails.cache.fetch([ "hardware_review_recordings", "lookout", @project.id ], expires_in: RECORDINGS_CACHE_TTL) do
      LookoutService.recordings_for_project(@project)
    end
  end

  # The .app-layout wrapper reserves the sidebar gutter itself; this body class
  # zeroes the body's own sidebar margin so the two don't stack into a huge gap.
  def set_body_class
    @body_class = "app-layout-page"
  end
end
