# frozen_string_literal: true

require_relative "test_helper"

# The bytes of the JSON a session exports.
#
# F6 moves the writer out of Session (Archive), and then the compactor out of
# it. Neither is allowed to move the file: it is read by /resume, by the store
# indexer and by whoever opens ~/.rubot/sessions by hand, and a renamed key or
# a reordered field is a silent break for all of them. So the whole file is
# pinned here, not just the fields a reader happens to touch.
#
# Timestamps are the only thing a run cannot reproduce, so they are the only
# thing replaced before the comparison. Everything else — keys, order, values,
# indentation — is compared byte for byte against the recorded export.
#
# To record a new golden file after a deliberate format change:
#   RUBOT_RECORD_EXPORT=1 ruby -Ilib -Itest test/test_session_export_format.rb
class TestSessionExportFormat < Minitest::Test
  GOLDEN = File.expand_path("fixtures/session_export.golden.json", __dir__)

  # A session carrying one of everything the file can hold: a tool round, the
  # reasoning that came with it, a UI-only diff, priced usage, cache records,
  # the pinned prompt with its epoch, the summary, the memory backlog and the
  # prompt patch. A field that is missing here is a field nothing protects.
  def build_session(dir)
    session = Rubot::Session.new("export-shape", workspace: dir, cwd: "/tmp/project")
    session.add("user", "halo, tolong lihat berkasnya")
    session.add("assistant", "", reasoning_content: "saya baca dulu",
                tool_calls: [ { "id" => "call_1", "type" => "function",
                                "function" => { "name" => "file_ops", "arguments" => "{\"operation\":\"read\"}" } } ])
    session.add("tool", "isi berkas", tool_call_id: "call_1",
                 ui_diff: { "path" => "a.txt", "before" => nil, "after" => "isi berkas" })
    session.add("assistant", "sudah saya baca", background: true)

    session.summary = "ringkasan percakapan"
    session.title = "Berkas"
    session.forced_skill = "file_ops"
    session.model_override = "openai/gpt-4o-mini"
    session.model_preset = "cepat"
    session.thinking_level = "low"

    session.record_usage(
      { "prompt_tokens" => 1_000, "completion_tokens" => 100,
        "prompt_tokens_details" => { "cached_tokens" => 500 } },
      rates: { "input" => 3.0, "output" => 15.0, "cached_input" => 0.3 },
      shape: { prompt_digest: "ab12", tool_digest: "cd34", blocks: 7 }
    )
    session.record_auxiliary_usage({ "prompt_tokens" => 50, "completion_tokens" => 5 },
                                   rates: { "input" => 3.0, "output" => 15.0 })
    session.push_memory_backlog("sesuatu yang perlu diingat")
    session.add_system_addition("tambahan untuk prompt")
    session.set_system_patch("# Prompt Update\n\nbagian yang lebih baru")
    session.store_system_prompt("PROMPT TERPIN", { "model" => "openai/gpt-4o-mini", "summary" => "d1" })
    session.record_compaction(cut_index: 3, summarized_messages: 2, context_before: 900,
                              context_after: 300, elapsed: 0.25)
    session.save!
    session
  end

  # The two ISO strings a run cannot pin: the messages' own timestamps and the
  # cache record's "at". Replacing them keeps the JSON's shape under comparison.
  def normalized(bytes)
    bytes.gsub(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:Z|[+-]\d\d:\d\d)?/, "TIMESTAMP")
  end

  def test_exported_json_matches_the_recorded_bytes
    Dir.mktmpdir("rubot-export") do |dir|
      session = build_session(dir)
      actual = normalized(File.read(session.file_path))

      if ENV["RUBOT_RECORD_EXPORT"]
        FileUtils.mkdir_p(File.dirname(GOLDEN))
        File.write(GOLDEN, actual)
      end

      assert File.exist?(GOLDEN), "record the fixture with RUBOT_RECORD_EXPORT=1"
      expected = File.read(GOLDEN)
      next if actual == expected

      # A line diff of two pretty-printed files is the fastest way to see which
      # key moved; the assertion below only fires when they differ.
      actual_lines = actual.lines
      expected_lines = expected.lines
      first = (0...[ actual_lines.size, expected_lines.size ].max).find do |i|
        actual_lines[i] != expected_lines[i]
      end
      flunk "the export changed at line #{first.to_i + 1}:\n" \
            "  expected: #{expected_lines[first].inspect}\n" \
            "  actual:   #{actual_lines[first].inspect}"
    end
  end
end
