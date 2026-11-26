# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"

# The actor tests intentionally exercise Ractors.
Warning[:experimental] = false if Warning.respond_to?(:[]=)

# A developer's real provider key must never reach a test. `Config#api_key`
# falls back to these variables, so an inherited key quietly changes what the
# suite sees — the settings page reports a stored key it was never given — and
# any path that would call a provider has something to call it with.
ENV.delete("RUBOT_API_KEY")
ENV.delete("OPENAI_API_KEY")

# Some tests create and delete files under $HOME (env-loader auto-detect,
# channel session cleanup). Point HOME at a scratch directory *before* rubot is
# loaded so Config::DEFAULT_CONFIG_DIR resolves there instead of the user's real
# ~/.rubot — otherwise running the suite wipes real sessions and ~/.rubot/.env.
TEST_HOME = Dir.mktmpdir("rubot-test-home")
ENV["HOME"] = TEST_HOME
Minitest.after_run do
  FileUtils.remove_entry(TEST_HOME) if File.directory?(TEST_HOME)
end

require_relative "../lib/rubot"

# Build a Config backed by an isolated temp workspace.
# Use this instead of `Config.new` so tests never read or write the real
# ~/.rubot/config.yml or ~/.rubot/workspace.
def isolated_config(dir, name: "test")
  workspace = File.join(dir, "workspace")
  FileUtils.mkdir_p(workspace)
  path = File.join(dir, "config.yml")
  File.write(path, {
    "agents" => { "defaults" => { "workspace" => workspace, "name" => name } },
    "models" => [
      {
        "name" => name,
        "model" => "openai/test-model",
        "api_key" => "sk-test",
        "api_base" => "http://127.0.0.1:1/v1"
      }
    ],
    "provider" => "openai"
  }.to_yaml)
  Rubot::Config.new(path)
end
