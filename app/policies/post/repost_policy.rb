class Post::RepostPolicy < ApplicationPolicy
  def create?
    logged_in?
  end

  def destroy?
    owns?
  end

  private
    def owns?
      user.present? && record.user == user
    end
end
