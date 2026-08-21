# frozen_string_literal: true

require "test_helper"

class SemanticSearchParseTest < ActiveSupport::TestCase
  test "parses RESP2 FT.SEARCH array replies" do
    raw = [
      1,
      "search:doc:project:12",
      [ "type", "project", "record_key", "project:12", "title", "Rocket" ],
      "not-a-doc",
      [ "type", "ignored" ]
    ]

    rows = SemanticSearch.send(:parse_redis_search, raw)

    assert_equal 1, rows.size
    assert_equal "project", rows.first["type"]
    assert_equal "project:12", rows.first["record_key"]
    assert_equal "Rocket", rows.first["title"]
  end

  test "parses RESP3 FT.SEARCH map replies" do
    raw = {
      "total_results" => 1,
      "results" => [
        {
          "id" => "search:doc:project:12",
          "extra_attributes" => {
            "type" => "project",
            "record_key" => "project:12",
            "title" => "Rocket"
          }
        },
        {
          "id" => "unrelated:9",
          "extra_attributes" => { "type" => "other", "record_key" => "other:9" }
        }
      ]
    }

    rows = SemanticSearch.send(:parse_redis_search, raw)

    assert_equal 1, rows.size
    assert_equal "project", rows.first["type"]
    assert_equal "project:12", rows.first["record_key"]
    assert_equal "Rocket", rows.first["title"]
  end

  test "parses RESP3 results that nest fields as a flat values array" do
    raw = {
      "results" => [
        {
          "id" => "search:doc:user:4",
          "values" => [ "type", "user", "record_key", "user:4" ]
        }
      ]
    }

    rows = SemanticSearch.send(:parse_redis_search, raw)

    assert_equal [ { "type" => "user", "record_key" => "user:4" } ], rows
  end

  test "returns an empty list for blank or unexpected replies" do
    assert_equal [], SemanticSearch.send(:parse_redis_search, nil)
    assert_equal [], SemanticSearch.send(:parse_redis_search, "oops")
    assert_equal [], SemanticSearch.send(:parse_redis_search, { "results" => nil })
  end
end
