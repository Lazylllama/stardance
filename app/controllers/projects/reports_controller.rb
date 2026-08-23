class Projects::ReportsController < ApplicationController
  def create
    authorize :report
    @project = ::Project.find(params[:project_id])

    return flag_should_not_have_been_approved if report_params[:reason] == Project::Report::SHOULD_NOT_HAVE_BEEN_APPROVED_REASON

    if current_user.reports.exists?(project: @project)
      redirect_back_or_to project_path(@project), alert: "You have already reported this project."
      return
    end

    @report = current_user.reports.build(report_params.merge(project: @project))

    if @report.save
      redirect_back_or_to project_path(@project), notice: "Report submitted. Thank you for helping us maintain quality."
    else
      redirect_back_or_to project_path(@project), alert: @report.errors.full_messages.to_sentence
    end
  end

  private

    def flag_should_not_have_been_approved
      result = Project::Report.flag_should_not_have_been_approved!(project: @project, reporter: current_user, details: report_params[:details])

      case result
      when :ok
        redirect_back_or_to project_path(@project), notice: "Thanks — we've flagged this for the reviewer to take a look."
      when :details_too_short
        redirect_back_or_to project_path(@project), alert: "Share a short explanation (20+ characters)."
      when :not_allowed
        redirect_back_or_to project_path(@project), alert: "You can't report your own project."
      when :throttled
        redirect_back_or_to project_path(@project), alert: "You've already flagged this project recently."
      when :not_approved
        redirect_back_or_to project_path(@project), alert: "This project hasn't been approved, so that reason doesn't apply."
      else
        redirect_back_or_to project_path(@project), alert: "Something went wrong. Please try again."
      end
    end

    def report_params
      params.require(:project_report).permit(:reason, :details)
    end
end
