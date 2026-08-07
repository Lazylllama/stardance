#!/usr/bin/env ruby
# frozen_string_literal: true

# One-time backfill for blank "Birthday" values in the Stardance YSWS Airtable
# table.
#
# Why they're blank: Certification::YswsAirtableSyncJob reads the birthday from
# User#birthday, which makes a live HCA /api/v1/me call with the member's stored
# OAuth access token. Nothing refreshes that token, so once it expires HCA
# returns 401, HCAService swallows it, and the job upserts Birthday => nil while
# still logging "Successfully synced". Roughly a fifth to a third of syncs are
# affected.
#
# This script repairs the historical rows by re-sourcing the birthday from the
# Unified YSWS base (the cross-program record of every approved YSWS
# submission), matching on email.
#
# The Stardance Airtable table is authoritative:
#   - the set of rows to repair comes from Airtable (Birthday blank), not from
#     certification_ysws_reviews;
#   - the email used for matching is the row's own Email field, not users.email;
#   - the Stardance database is never read or written.
#
# Only the Birthday field is ever written. Nothing else on the record is
# touched, and the sync job is deliberately not re-run: it re-upserts every
# field (re-running the OpenRouter summary call), and its
# check_stardance_review_submitted_unified guard raises outright for any review
# already migrated to the unified DB.
#
# Land the "omit Birthday when nil" guard in the sync job BEFORE running this,
# otherwise the next ordinary re-sync of a repaired review blanks it again.
#
# Usage:
#   rails runner script/backfill_ysws_birthdays_from_unified.rb            # dry run, reports only
#   APPLY=1 rails runner script/backfill_ysws_birthdays_from_unified.rb    # actually writes
#   LIMIT=25 rails runner script/backfill_ysws_birthdays_from_unified.rb   # first 25 rows only

require "erb"

APPLY = ENV["APPLY"] == "1"
LIMIT = ENV["LIMIT"].presence&.to_i

# Stardance side — same credential lookups as Certification::YswsAirtableSyncJob.
STARDANCE_BASE_ID = Rails.application.credentials.dig(:ysws_review, :airtable_base_id) ||
  ENV["YSWS_REVIEW_AIRTABLE_BASE_ID"]
STARDANCE_TABLE = Rails.application.credentials.dig(:ysws_review, :airtable_table_name) ||
  ENV["YSWS_REVIEW_AIRTABLE_TABLE"] ||
  "YSWS Project Submission"
STARDANCE_API_KEY = Rails.application.credentials.dig(:ysws_review, :airtable_api_key) ||
  Rails.application.credentials&.airtable&.api_key ||
  ENV["AIRTABLE_API_KEY"]

# Unified side — read-only, same base/table/credential as UnifiedYswsService.
UNIFIED_BASE_ID = Certification::UnifiedYswsService::BASE_ID
UNIFIED_TABLE_ID = Certification::UnifiedYswsService::TABLE_ID
UNIFIED_API_KEY = Rails.application.credentials.dig(:unified_ysws, :airtable_api_key) ||
  ENV["UNIFIED_READ_ONLY"]

EMAIL_FIELD = "Email"
BIRTHDAY_FIELD = "Birthday"
REVIEW_ID_FIELD = "review_id"

# Airtable allows 5 requests/second per base; stay well under it.
THROTTLE_SECONDS = 0.25
REQUEST_TIMEOUT = 15
MAX_RETRIES = 3

# ---------------------------------------------------------------------------
# Airtable helpers
# ---------------------------------------------------------------------------

def airtable_url(base_id, table)
  "https://api.airtable.com/v0/#{base_id}/#{ERB::Util.url_encode(table)}"
end

# The email is interpolated into a double-quoted Airtable formula string, where
# only a quote or a backslash could break out of the literal. Rather than escape
# them, refuse to look up any address containing one (or whitespace/control
# characters) — none of those can appear in an address we'd match on, so an
# email carrying one is malformed or hostile either way.
SAFE_EMAIL = /\A[^"\\[:space:][:cntrl:]]+@[^"\\[:space:][:cntrl:]]+\z/

def airtable_get(url, api_key, params)
  attempt = 0

  begin
    attempt += 1
    response = Faraday.get(url) do |req|
      params.each { |key, value| req.params[key] = value }
      req.headers["Authorization"] = "Bearer #{api_key}"
      req.options.timeout = REQUEST_TIMEOUT
    end

    # 429 is a rate limit; Airtable asks for a 30s backoff.
    if response.status == 429 && attempt <= MAX_RETRIES
      sleep 30
      raise "rate limited"
    end

    raise "HTTP #{response.status} — #{response.body}" unless response.success?

    JSON.parse(response.body)
  rescue StandardError => e
    retry if attempt <= MAX_RETRIES
    raise e
  end
end

def airtable_patch(url, api_key, record_id, fields)
  response = Faraday.patch("#{url}/#{record_id}") do |req|
    req.headers["Authorization"] = "Bearer #{api_key}"
    req.headers["Content-Type"] = "application/json"
    req.options.timeout = REQUEST_TIMEOUT
    req.body = { "fields" => fields }.to_json
  end

  raise "HTTP #{response.status} — #{response.body}" unless response.success?

  JSON.parse(response.body)
end

# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------

# Every Stardance row missing a birthday but carrying an email to match on.
def stardance_rows_missing_birthday
  url = airtable_url(STARDANCE_BASE_ID, STARDANCE_TABLE)
  rows = []
  offset = nil

  loop do
    params = {
      "filterByFormula" => "AND({#{BIRTHDAY_FIELD}} = BLANK(), {#{EMAIL_FIELD}} != BLANK())",
      "pageSize" => 100
    }
    [ EMAIL_FIELD, BIRTHDAY_FIELD, REVIEW_ID_FIELD ].each_with_index do |field, index|
      params["fields[#{index}]"] = field
    end
    params["offset"] = offset if offset

    body = airtable_get(url, STARDANCE_API_KEY, params)
    rows.concat(body.fetch("records", []))

    offset = body["offset"]
    break if offset.blank?
    break if LIMIT && rows.size >= LIMIT

    sleep THROTTLE_SECONDS
  end

  LIMIT ? rows.first(LIMIT) : rows
end

# Distinct birthdays recorded against this email anywhere in the unified base.
# More than one means the source data disagrees with itself, and the caller
# skips rather than guessing. Callers must screen the email against SAFE_EMAIL
# first — it is interpolated straight into the lookup formula.
def unified_birthdays_for(email)
  body = airtable_get(
    airtable_url(UNIFIED_BASE_ID, UNIFIED_TABLE_ID),
    UNIFIED_API_KEY,
    {
      "filterByFormula" => %(LOWER({#{EMAIL_FIELD}}) = "#{email.to_s.strip.downcase}"),
      "fields[0]" => EMAIL_FIELD,
      "fields[1]" => BIRTHDAY_FIELD,
      "pageSize" => 100
    }
  )

  body.fetch("records", [])
      .filter_map { |record| normalize_birthday(record.dig("fields", BIRTHDAY_FIELD)) }
      .uniq
end

# Airtable date fields come back as "2008-05-01" or a full ISO timestamp
# depending on how the field is configured; normalise both to a plain ISO date.
def normalize_birthday(raw)
  return nil if raw.blank?

  Date.parse(raw.to_s).iso8601
rescue ArgumentError
  nil
end

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

missing_config = {
  "Stardance base id" => STARDANCE_BASE_ID,
  "Stardance API key" => STARDANCE_API_KEY,
  "Unified API key (credentials.unified_ysws.airtable_api_key / UNIFIED_READ_ONLY)" => UNIFIED_API_KEY
}.select { |_label, value| value.blank? }.keys

if missing_config.any?
  abort "Missing configuration: #{missing_config.join(', ')}"
end

puts "YSWS birthday backfill — #{APPLY ? 'APPLY (writing to Airtable)' : 'DRY RUN (no writes)'}"
puts "  Stardance : #{STARDANCE_BASE_ID} / #{STARDANCE_TABLE}"
puts "  Unified   : #{UNIFIED_BASE_ID} / #{UNIFIED_TABLE_ID} (read-only)"
puts "  Limit     : #{LIMIT || 'none'}"
puts

# ---------------------------------------------------------------------------
# Backfill
# ---------------------------------------------------------------------------

rows = stardance_rows_missing_birthday
puts "Found #{rows.size} Stardance row(s) with a blank #{BIRTHDAY_FIELD}."
puts

stardance_url = airtable_url(STARDANCE_BASE_ID, STARDANCE_TABLE)
unified_cache = {}
counts = Hash.new(0)

rows.each do |row|
  fields = row.fetch("fields", {})
  email = fields[EMAIL_FIELD].to_s.strip
  review_id = fields[REVIEW_ID_FIELD].presence || "?"
  label = "review ##{review_id} (#{row['id']}, #{email})"

  unless email.match?(SAFE_EMAIL)
    counts[:unsafe_email] += 1
    puts "  SKIP    #{label} — email is not a well-formed address, not looking it up"
    next
  end

  cache_key = email.downcase
  unless unified_cache.key?(cache_key)
    unified_cache[cache_key] = unified_birthdays_for(email)
    sleep THROTTLE_SECONDS
  end
  birthdays = unified_cache[cache_key]

  case birthdays.size
  when 0
    counts[:no_match] += 1
    puts "  SKIP    #{label} — no birthday in unified"
    next
  when 1
    # fall through
  else
    counts[:conflict] += 1
    puts "  SKIP    #{label} — unified disagrees: #{birthdays.join(', ')}"
    next
  end

  birthday = birthdays.first

  if APPLY
    begin
      airtable_patch(stardance_url, STARDANCE_API_KEY, row["id"], { BIRTHDAY_FIELD => birthday })
      counts[:updated] += 1
      puts "  UPDATED #{label} → #{birthday}"
      sleep THROTTLE_SECONDS
    rescue StandardError => e
      counts[:error] += 1
      puts "  ERROR   #{label} — #{e.class}: #{e.message}"
    end
  else
    counts[:would_update] += 1
    puts "  WOULD   #{label} → #{birthday}"
  end
end

puts
puts "Scanned      : #{rows.size}"
puts "#{APPLY ? 'Updated      ' : 'Would update '}: #{APPLY ? counts[:updated] : counts[:would_update]}"
puts "No match     : #{counts[:no_match]}"
puts "Conflicting  : #{counts[:conflict]}"
puts "Unsafe email : #{counts[:unsafe_email]}" if counts[:unsafe_email].positive?
puts "Errors       : #{counts[:error]}" if counts[:error].positive?
puts
puts "Dry run — re-run with APPLY=1 to write." unless APPLY
