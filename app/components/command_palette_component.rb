class CommandPaletteComponent < ViewComponent::Base
  def initialize(current_user:)
    @current_user = current_user
  end

  def initial_commands = Command.for_user(@current_user)

  def user_search_url
    helpers.admin_search_admin_users_path if @current_user.admin? || @current_user.helper?
  end

  def project_search_url
    helpers.admin_search_admin_projects_path if @current_user.admin? || @current_user.helper?
  end
end
