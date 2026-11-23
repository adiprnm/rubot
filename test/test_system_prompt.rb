# frozen_string_literal: true

require_relative "test_helper"

# The exact bytes of the system prompt, held still.
#
# Every other prompt test asserts a rule (memory is last, a skill that is
# switched off is named, a persona replaces the config prompt). This one
# asserts the assembled text, because the assembled text is what the provider
# caches: a reworded heading or a moved section costs every running session one
# uncached request, and no rule-shaped assertion notices it.
#
# The digests below are characterization values, not a specification. When the
# shipped rules change on purpose, they change with them, and that update is
# the moment someone says out loud that the prefix moves. Never rewrite a
# number just to make a red test green: a prompt that moved by accident is
# exactly what this file exists to catch.
class TestSystemPrompt < Minitest::Test
  # SHA1 of the prompt, with the temporary directory replaced by "<root>" so
  # the number does not depend on where the suite runs.
  PLAIN_PROMPT = "adb6b9e71e7d51a603c57b0dfe6b121e35a9a23d"
  RICH_PROMPT = "a26387846b1953ee459db2f116238d869adac206"
  CHANGE_PATCH = "74fb59b8e45b2a4e0c20614d4ad727bed5b2e311"

  # The fingerprint a session pins its prompt under, key by key. Anything that
  # moves here is a pin a running session has to rebuild; an empty input is the
  # digest of "" and means "nothing to say yet".
  PLAIN_EPOCH = {
    "model" => "f5b4a6aa4ae011ab1607bf68cc669b914bf30700",
    "rules" => "805abefced9aa11f4449d3f81e0e2942758b4d2b",
    "persona" => "da39a3ee5e6b4b0d3255bfef95601890afd80709",
    "summary" => "da39a3ee5e6b4b0d3255bfef95601890afd80709",
    "skill" => "da39a3ee5e6b4b0d3255bfef95601890afd80709",
    "task" => "da39a3ee5e6b4b0d3255bfef95601890afd80709"
  }.freeze
  RICH_EPOCH = PLAIN_EPOCH.merge("persona" => "81e8a8e25efa859cbdcfa4575a29bdffde64552b").freeze

  def setup
    @root = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  def sha(text)
    Digest::SHA1.hexdigest(text.to_s)
  end

  # Where the suite happens to run is not content. Only the skills section names
  # an absolute path, and it is the one thing a temp directory would leak into
  # every digest.
  def normalize(text)
    text.to_s.gsub(@root, "<root>")
  end

  def write_config(dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "config.yml"), {
      "agents" => { "defaults" => { "workspace" => File.join(dir, "workspace") } },
      "models" => [
        { "name" => "model-a", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" }
      ]
    }.to_yaml)
    FileUtils.mkdir_p(File.join(dir, "workspace"))
    Rubot::Config.new(File.join(dir, "config.yml"))
  end

  def write_skill(dir, name, description)
    FileUtils.mkdir_p(File.join(dir, "skills", name))
    File.write(File.join(dir, "skills", name, "SKILL.md"),
               "---\nname: #{name}\ndescription: #{description}\n---\n\n# #{name.capitalize}\n\nDo the thing.\n")
  end

  # An install that configured nothing beyond a model.
  def plain_agent
    dir = File.join(@root, "plain")
    Rubot::Agent.new(config: write_config(dir), session_id: "plain")
  end

  # Everything a prompt can be built from: identity, rules, memory, two skills
  # (one of them switched off) and a persona.
  def rich_config
    dir = File.join(@root, "rich")
    config = write_config(dir)
    File.write(File.join(dir, "workspace", "SOUL.md"), "# Soul\n\nTenang, ringkas, dan langsung.\n")
    File.write(File.join(dir, "workspace", "AGENTS.md"), "# Agent Rules\n\nSelalu jawab dalam Bahasa Indonesia.\n")
    File.write(File.join(dir, "MEMORY.md"), "## Facts\n\n- User suka kopi.\n")
    write_skill(dir, "demo", "A demo skill.")
    write_skill(dir, "off", "A switched-off skill.")
    config
  end

  def persona
    Rubot::Persona.new(name: "Kanyaah", emoji: "🤖",
                       system_prompt: "Kamu menjawab sebagai Kanyaah.",
                       skills: [ "demo" ], disabled_skills: [ "off" ])
  end

  def assert_prompt(expected, agent)
    prompt = agent.build_system_prompt
    assert_equal expected, sha(normalize(prompt)),
                 "the composed prompt moved (#{prompt.length} chars). If the rules changed on " \
                 "purpose, update the digest in this file and know that every running session " \
                 "pays one uncached request for it."
  end

  def test_a_plain_install_composes_the_same_prompt
    agent = plain_agent
    assert_prompt(PLAIN_PROMPT, agent)
    assert_equal PLAIN_EPOCH, agent.system_prompt.epoch.transform_values { |value| sha(value) }
  end

  def test_a_persona_with_everything_composes_the_same_prompt
    agent = Rubot::Agent.new(config: rich_config, session_id: "rich", persona: persona)
    assert_prompt(RICH_PROMPT, agent)
    assert_equal RICH_EPOCH, agent.system_prompt.epoch.transform_values { |value| sha(value) }
  end

  # The pin is the whole reason the composition has to be stable: the second
  # build hands back the first one's bytes without composing anything.
  def test_a_pinned_prompt_comes_back_byte_identical
    agent = Rubot::Agent.new(config: rich_config, session_id: "pinned", persona: persona)
    first = agent.build_system_prompt
    second = agent.build_system_prompt

    assert_equal first, second
    assert_equal RICH_PROMPT, sha(normalize(first))
  end

  # A skill installed after the pin reaches the model as a patch: the sections
  # that changed, and nothing in front of them.
  def test_a_skill_installed_after_the_pin_arrives_as_a_patch
    config = rich_config
    agent = Rubot::Agent.new(config: config, session_id: "patched", persona: persona)
    pinned = agent.build_system_prompt

    write_skill(File.dirname(config.config_path), "extra", "Installed later.")
    patch = agent.system_prompt.patch(pinned, composed: agent.compose_system_prompt)

    refute_nil patch
    assert_equal CHANGE_PATCH, sha(normalize(patch))
    assert_includes patch, Rubot::Agent::PROMPT_PATCH_HEADER
  end
end
