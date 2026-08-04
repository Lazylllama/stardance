# == Schema Information
#
# Table name: certification_mac_analyses
#
#  id             :bigint           not null, primary key
#  generated_at   :datetime         not null
#  report         :jsonb            not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  ysws_review_id :bigint           not null
#
# Indexes
#
#  index_certification_mac_analyses_on_ysws_review_id  (ysws_review_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (ysws_review_id => certification_ysws_reviews.id)
#
class Certification::MACAnalysis < ApplicationRecord
  self.table_name = "certification_mac_analyses"

  has_paper_trail

  belongs_to :ysws_review, class_name: "Certification::Ysws",
    foreign_key: :ysws_review_id

  validates :report, presence: true
  validates :generated_at, presence: true
  validates :ysws_review_id, uniqueness: true
end
