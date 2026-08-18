# frozen_string_literal: true

module Certification
  # Reverses a completed (or returned) YSWS review so it lands back in the
  # pending queue, and removes the review's Airtable submission record.
  #
  # This is the inverse of Admin::Certification::YswsController#complete: it
  # clears every field that decision stamped, drops the claim so the review is
  # up for grabs again, and deletes the row the sync job upserted into the YSWS
  # Project Submission table. Devlog verdicts are deliberately left alone — the
  # reviewer's per-devlog work survives so the review can simply be completed
  # again.
  #
  # It does NOT reach the Unified YSWS base. Once a submission has been picked
  # up there (in_unified_db), that downstream record has to be removed by hand.
  class YswsReviewUndoer
    Result = Struct.new(:undone, :airtable_record_deleted, keyword_init: true)

    attr_reader :review

    def initialize(review)
      @review = review
    end

    def call
      return Result.new(undone: false, airtable_record_deleted: false) if review.pending?

      # Airtable first, on purpose: it can't take part in the DB transaction, so
      # a failed delete has to abort before anything is written rather than
      # leaving a stale submission row behind a pending review.
      deleted = delete_airtable_record

      # update! rather than the #complete action's update_columns, so the audit
      # trail carries the reversal.
      review.update!(
        reviewed_at: nil,
        returned_at: nil,
        reviewer_id: nil,
        in_unified_db: nil,
        airtable_synced_at: nil,
        claimed_by_id: nil,
        claimed_at: nil
      )

      Rails.logger.info "[YswsReviewUndoer] review=#{review.id} reset to pending " \
                        "airtable_record_deleted=#{deleted}"

      Result.new(undone: true, airtable_record_deleted: deleted)
    end

    private

    # True when a record was found and deleted. A record that isn't there is
    # success — there is nothing left to remove.
    def delete_airtable_record
      record = ::Certification::YswsAirtable.record_for(review.id)
      return false if record.nil?

      record.destroy
      true
    rescue Norairrecord::RecordNotFoundError
      false
    end
  end
end
