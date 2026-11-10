# frozen_string_literal: true

require_relative "test_helper"

class TestPersona < Minitest::Test
  def test_from_hash_with_string_keys
    persona = Rubot::Persona.from(
      "name" => "trading",
      "model" => "claude-sonnet",
      "system_prompt" => "Kamu adalah asisten trading.",
      "created_at" => "2026-02-11T10:00:00Z"
    )

    assert_equal "trading", persona.name
    assert_equal "claude-sonnet", persona.model
    assert_equal "Kamu adalah asisten trading.", persona.system_prompt
    assert_equal "2026-02-11T10:00:00Z", persona.created_at
  end

  def test_from_hash_with_symbol_keys
    persona = Rubot::Persona.from(model: "llama3", system_prompt: "Halo")

    assert_equal "llama3", persona.model
    assert_equal "Halo", persona.system_prompt
  end

  def test_from_blank_hash_is_nil
    assert_nil Rubot::Persona.from({})
    assert_nil Rubot::Persona.from("name" => "  ", "system_prompt" => "")
  end

  def test_to_h_round_trips
    persona = Rubot::Persona.new(name: "trading", model: "llama3", system_prompt: "Halo")
    restored = Rubot::Persona.from(persona.to_h)

    assert_equal persona.name, restored.name
    assert_equal persona.model, restored.model
    assert_equal persona.system_prompt, restored.system_prompt
  end
end

class TestPersonaStore < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @store = Rubot::PersonaStore.new(
      workspace: @workspace,
      available_models: %w[gpt-4o-mini claude-sonnet]
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def persona(model: "claude-sonnet", prompt: "Kamu adalah asisten trading.")
    Rubot::Persona.new(name: "trading", model: model, system_prompt: prompt)
  end

  def test_set_and_get_round_trip
    @store.set("123:45", persona)

    fresh = Rubot::PersonaStore.new(workspace: @workspace, available_models: %w[gpt-4o-mini claude-sonnet])
    stored = fresh.get(123, 45)

    assert_equal "trading", stored.name
    assert_equal "claude-sonnet", stored.model
    assert_equal "Kamu adalah asisten trading.", stored.system_prompt
  end

  def test_file_shape_is_documented_json
    @store.set("-1001234567890:42", persona)

    data = JSON.parse(File.read(File.join(@workspace, "personas.json")))

    assert_equal [ "-1001234567890:42" ], data.keys
    assert_equal "trading", data["-1001234567890:42"]["name"]
    assert_equal "claude-sonnet", data["-1001234567890:42"]["model"]
    assert_equal "Kamu adalah asisten trading.", data["-1001234567890:42"]["system_prompt"]
    refute_nil data["-1001234567890:42"]["created_at"]
  end

  def test_key_for_rejects_threadless_and_non_numeric_keys
    assert_nil Rubot::PersonaStore.key_for(123, nil)
    assert_nil Rubot::PersonaStore.key_for(nil, 4)
    assert_nil Rubot::PersonaStore.key_for("abc", 4)
    assert_nil Rubot::PersonaStore.key_for(123, "4; rm -rf /")
    assert_equal "-100123:42", Rubot::PersonaStore.key_for(-100_123, 42)
  end

  def test_key_for_session_parses_telegram_session_ids
    assert_equal "-100123:42", Rubot::PersonaStore.key_for_session("tg_-100123_42")
    assert_equal "123:7", Rubot::PersonaStore.key_for_session("tg_123_7")
    assert_nil Rubot::PersonaStore.key_for_session("tg_123")
    assert_nil Rubot::PersonaStore.key_for_session("default")
  end

  # A persona can own many conversations. Every one of them has to resolve back
  # to the persona, because the workspace (SOUL, skills, memory) hangs off it.
  def test_key_for_session_ignores_the_session_suffix
    assert_equal "kanyaah", Rubot::PersonaStore.key_for_session("web_kanyaah")
    assert_equal "kanyaah", Rubot::PersonaStore.key_for_session("web_kanyaah~20261108-101010")
    assert_equal "kanyaah", Rubot::PersonaStore.key_for_session("web_kanyaah~20261108-101010-2")
    assert_equal "by-adipurnm_2",
                 Rubot::PersonaStore.key_for_session("web_by-adipurnm_2~20261108-101010")
    assert_nil Rubot::PersonaStore.key_for_session("web_kanyaah~")
    assert_nil Rubot::PersonaStore.key_for_session("web_")
  end

  # The terminal has no topics and no pages, so a fired job that names a
  # persona gets a conversation of its own there.
  def test_key_for_session_parses_terminal_session_ids
    assert_equal "english-tutor", Rubot::PersonaStore.key_for_session("tui_english-tutor")
    assert_equal "english-tutor", Rubot::PersonaStore.key_for_session("tui_english-tutor~20261110-210000")
    assert_nil Rubot::PersonaStore.key_for_session("tui_")
  end

  def test_get_by_session
    @store.set("123:7", persona)

    assert_equal "claude-sonnet", @store.get_by_session("tg_123_7").model
    assert_nil @store.get_by_session("tg_123")
  end

  def test_set_rejects_invalid_keys
    error = assert_raises(ArgumentError) { @store.set("Not A Slug", persona) }
    assert_includes error.message, "invalid persona key"

    # A slug is a valid key now; a reserved one is not.
    assert_equal "trading", @store.set("trading", persona).name
    assert_raises(ArgumentError) { @store.set("default", persona) }
  end

  def test_delete
    @store.set("123:45", persona)

    removed = @store.delete("123:45")

    assert_equal "trading", removed.name
    assert_nil @store.get(123, 45)
  end

  def test_unknown_model_falls_back_to_default
    @store.set("123:45", persona(model: "model-that-was-removed"))

    assert_nil @store.get(123, 45).model
  end

  def test_unknown_model_is_kept_when_no_model_list_is_known
    store = Rubot::PersonaStore.new(workspace: @workspace)
    store.set("123:45", persona(model: "custom"))

    assert_equal "custom", store.get(123, 45).model
  end

  def test_unreadable_json_yields_empty_store
    File.write(File.join(@workspace, "personas.json"), "{ not json")

    assert_empty @store.all
  end

  def test_malformed_entries_are_skipped
    File.write(File.join(@workspace, "personas.json"), JSON.generate(
      "123:45" => { "name" => "ok", "model" => "gpt-4o-mini" },
      "bad key" => { "name" => "nope" },
      "999:1" => {}
    ))

    personas = @store.all

    assert_equal [ "123:45" ], personas.keys
    assert_equal "ok", personas["123:45"].name
  end

  def test_general_topic_has_no_persona_key
    assert_nil @store.get(123, nil)
    assert_nil @store.key_for(123, nil)
  end

  # A forum topic may borrow a specialist instead of defining its own prompt.
  # It keeps its own session; what it shares is the persona and therefore the
  # memory that hangs off the persona's directory.
  def test_a_topic_can_point_at_an_existing_persona
    @store.set("kanyaah", Rubot::Persona.new(name: "Kanyaah", emoji: "🧠"))
    @store.set("123:7", Rubot::Persona.new(ref: "kanyaah"))

    resolved = @store.get(123, 7)

    assert_equal "kanyaah", resolved.slug
    assert_equal "Kanyaah", resolved.name
    assert_equal @store.workspace_for("kanyaah"), @store.workspace_for("123:7"),
                 "a borrowed persona brings its workspace, and its memory"
    assert_equal "kanyaah", @store.resolved_slug("123:7")
  end

  def test_a_topic_that_defines_its_own_prompt_owns_no_workspace
    @store.set("123:7", persona)

    assert_nil @store.workspace_for("123:7")
    assert_nil @store.resolved_slug("123:7")
  end

  def test_a_dangling_reference_resolves_to_nothing
    @store.set("123:7", Rubot::Persona.new(ref: "nobody"))

    assert_nil @store.get(123, 7)
    assert_nil @store.workspace_for("123:7")
  end

  # Sessions must not follow the reference: two topics on one persona still
  # have two conversations, one file each.
  def test_borrowed_personas_keep_their_own_sessions
    assert_equal "123:7", Rubot::PersonaStore.key_for_session("tg_123_7")
    assert_equal "124:7", Rubot::PersonaStore.key_for_session("tg_124_7")
  end

  def test_skills_survive_a_round_trip
    @store.set("123:7", Rubot::Persona.new(
      name: "Kanyaah",
      skills: "kanyaah-brand, marketing-strategist"
    ))

    assert_equal %w[kanyaah-brand marketing-strategist], @store.get(123, 7).skills
  end
end

class TestPersonaStorePresets < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @store = Rubot::PersonaStore.new(
      workspace: @workspace,
      available_models: %w[gpt-4o-mini],
      available_presets: %w[fast deep]
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_preset_round_trips
    persona = Rubot::Persona.new(name: "trading", preset: "deep", system_prompt: "Jawab singkat.")

    @store.set("123:45", persona)
    stored = @store.get(123, 45)

    assert_equal "deep", stored.preset
    assert_nil stored.model
    assert_equal "deep", stored.to_h["preset"]
  end

  def test_unknown_preset_is_cleared
    @store.set("123:45", Rubot::Persona.new(name: "x", preset: "missing"))

    stored = @store.get(123, 45)

    assert_nil stored.preset
  end

  def test_default_and_primary_are_always_valid_presets
    @store.set("123:45", Rubot::Persona.new(name: "x", preset: "default"))
    @store.set("123:46", Rubot::Persona.new(name: "y", preset: "primary"))

    assert_equal "default", @store.get(123, 45).preset
    assert_equal "primary", @store.get(123, 46).preset
  end
end
