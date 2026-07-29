# == Schema Information
#
# Table name: lookout_sessions
#
#  id               :bigint           not null, primary key
#  duration_seconds :integer          default(0)
#  mode             :string
#  recording_url    :string
#  started_at       :datetime
#  status           :string           default("pending")
#  stopped_at       :datetime
#  token            :string           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  devlog_id        :bigint
#  project_id       :bigint           not null
#  user_id          :bigint           not null
#
# Indexes
#
#  index_lookout_sessions_on_devlog_id              (devlog_id)
#  index_lookout_sessions_on_project_id             (project_id)
#  index_lookout_sessions_on_project_id_and_status  (project_id,status)
#  index_lookout_sessions_on_token                  (token) UNIQUE
#  index_lookout_sessions_on_user_id                (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (devlog_id => post_devlogs.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
# Historical record of a Lookout recording. Stardance stopped recording with
# Lookout when hardware time moved to Lapse, so nothing writes these rows any
# more; they exist so the ~7.3k finished recordings already attached to projects
# stay viewable on the hardware review pages (see LookoutService).
class LookoutSession < ApplicationRecord
  STATUSES = %w[pending active paused stopped compiling complete failed].freeze
  # How the session was recorded (desktop / web / camera).
  MODES = %w[desktop web camera].freeze

  belongs_to :user
  belongs_to :project

  validates :token, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :mode, inclusion: { in: MODES }, allow_nil: true

  # Sessions that got far enough to have something worth showing a reviewer.
  scope :attachable, -> { where(status: %w[stopped complete]) }
end
