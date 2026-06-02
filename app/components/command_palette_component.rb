class CommandPaletteComponent < ViewComponent::Base
  def initialize(current_user:, current_path: nil)
    @current_user = current_user
    @current_path = current_path
  end

  def initial_commands = Command.for_user(@current_user, current_path: @current_path)

  def user_search_url
    helpers.admin_search_admin_users_path if @current_user.admin? || @current_user.helper?
  end

  def project_search_url
    helpers.admin_search_admin_projects_path if @current_user.admin? || @current_user.helper?
  end

  def mission_search_url
    helpers.search_missions_path
  end
end
