# frozen_string_literal: true

require_relative "test_helper"

class TestCacheProbe < Minitest::Test
  Tool = Struct.new(:name, :description, :parameters)

  def tool(name, description = "does a thing")
    Tool.new(name, description, { "type" => "object", "properties" => {} })
  end

  # Named `msg`, not `message`: Minitest::Assertions already owns `message`,
  # and overriding it turns every assertion failure into a broken payload.
  def msg(role, content)
    { "role" => role, "content" => content }
  end

  def fingerprint(system: "SYSTEM", tools: [ tool("shell") ], messages: [ msg("user", "halo") ])
    Rubot::CacheProbe.fingerprint(system: system, tools: tools, messages: messages)
  end

  def test_blocks_run_system_then_tools_then_messages
    mark = fingerprint(
      system: "S",
      tools: [ tool("shell"), tool("file") ],
      messages: [ msg("user", "satu"), msg("assistant", "dua") ]
    )

    assert_equal 5, Rubot::CacheProbe.block_count(mark)
    assert_equal "s", mark.split(",")[0][0]
    assert_equal %w[s t t m m], mark.split(",").map { |block| block[0] }
  end

  def test_an_unchanged_request_matches_everything
    mark = fingerprint

    assert_equal(-1, Rubot::CacheProbe.first_divergence(mark, mark))
  end

  def test_an_appended_request_still_matches
    before = fingerprint(messages: [ msg("user", "halo") ])
    after = fingerprint(messages: [ msg("user", "halo"), msg("assistant", "hai") ])

    assert_equal(-1, Rubot::CacheProbe.first_divergence(before, after),
                 "a request that only appended has the prefix of a request that hits")
  end

  def test_a_rewritten_message_reports_its_own_index
    before = fingerprint(messages: [ msg("user", "halo"), msg("assistant", "hai") ])
    after = fingerprint(messages: [ msg("user", "halo"), msg("assistant", "HALO JUGA") ])

    assert_equal 3, Rubot::CacheProbe.first_divergence(before, after),
                 "system is 0, the tool is 1, the first message 2, so the rewritten second message is 3"
  end

  def test_a_changed_system_prompt_reports_zero
    before = fingerprint(system: "SYSTEM LAMA")
    after = fingerprint(system: "SYSTEM BARU")

    assert_equal 0, Rubot::CacheProbe.first_divergence(before, after)
  end

  def test_a_changed_tool_reports_its_position
    before = fingerprint(tools: [ tool("shell"), tool("file") ])
    after = fingerprint(tools: [ tool("shell"), tool("file", "deskripsi baru") ])

    assert_equal 2, Rubot::CacheProbe.first_divergence(before, after)
  end

  def test_a_reordered_tool_reports_the_first_position_that_moved
    before = fingerprint(tools: [ tool("shell"), tool("file") ])
    after = fingerprint(tools: [ tool("file"), tool("shell") ])

    assert_equal 1, Rubot::CacheProbe.first_divergence(before, after)
  end

  def test_a_trimmed_history_is_reported_where_it_was_cut
    before = fingerprint(messages: [ msg("user", "satu"), msg("user", "dua") ])
    after = fingerprint(messages: [ msg("user", "dua") ])

    assert_equal 2, Rubot::CacheProbe.first_divergence(before, after),
                 "the cut history matches for one block, then runs out"
  end

  def test_the_first_request_of_a_session_has_nothing_to_compare_against
    assert_nil Rubot::CacheProbe.first_divergence(nil, fingerprint)
    assert_nil Rubot::CacheProbe.first_divergence(fingerprint, nil)
  end

  def test_a_reader_can_name_the_block_that_moved
    probe = Rubot::CacheProbe

    assert_equal "s", probe.block_kind(0, tools: 2)
    assert_equal "t", probe.block_kind(1, tools: 2)
    assert_equal "t", probe.block_kind(2, tools: 2)
    assert_equal "m", probe.block_kind(3, tools: 2)
    assert_nil probe.block_kind(nil, tools: 2)
    assert_nil probe.block_kind(-1, tools: 2)
  end

  def test_a_message_is_fingerprinted_by_its_payload_not_its_object_id
    one = fingerprint(messages: [ msg("user", "halo") ])
    two = fingerprint(messages: [ { "content" => "halo", "role" => "user" } ])

    refute_equal one, two,
                 "the same words in a different key order are a different payload on the wire"
  end
end
