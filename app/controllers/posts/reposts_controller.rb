class Posts::RepostsController < ApplicationController
  before_action :set_original_post

  def create
    @repost = Post::Repost.new(repost_params.merge(original_post: @original_post, user: current_user))
    authorize @repost

    if existing_repost.present?
      redirect_back fallback_location: fallback_path, alert: "You've already reposted this devlog."
    else
      create_repost
    end
  end

  def destroy
    @repost = existing_repost || raise(ActiveRecord::RecordNotFound)
    authorize @repost

    @repost.soft_delete!

    redirect_back fallback_location: fallback_path, notice: "Repost removed."
  end

  private
    def set_original_post
      @original_post = Post.of_devlogs(join: true)
                           .visible_to(current_user)
                           .where(post_devlogs: { deleted_at: nil })
                           .find(params[:post_id])
    end

    def create_repost
      ActiveRecord::Base.transaction do
        @repost.save!
        Post.create!(user: current_user, postable: @repost)
      end

      redirect_back fallback_location: fallback_path, notice: "Reposted."
    rescue ActiveRecord::RecordInvalid
      redirect_back fallback_location: fallback_path, alert: @repost.errors.full_messages.to_sentence
    rescue ActiveRecord::RecordNotUnique
      redirect_back fallback_location: fallback_path, alert: "You've already reposted this devlog."
    end

    def existing_repost
      if current_user.present?
        @existing_repost ||= Post::Repost.find_by(original_post: @original_post, user: current_user)
      end
    end

    def repost_params
      params.fetch(:post_repost, {}).permit(:body)
    end

    def fallback_path
      project = @original_post.project
      project.present? ? project_path(project, anchor: helpers.dom_id(@original_post)) : home_path
    end
end
