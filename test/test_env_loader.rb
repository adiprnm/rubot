# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

module Rubot
  class TestEnvLoader < Minitest::Test
    def setup
      @original_env = ENV.to_h
    end

    def teardown
      # Restore original ENV
      @original_env.each { |k, v| ENV[k] = v }
      (@original_env.keys - ENV.keys).each { |k| ENV.delete(k) }
      (ENV.keys - @original_env.keys).each { |k| ENV.delete(k) }
    end

    def test_load_simple_key_value
      with_env_file("FOO=bar\n") do |path|
        EnvLoader.load(path)
        assert_equal "bar", ENV["FOO"]
      end
    end

    def test_load_double_quoted
      with_env_file('FOO="hello world"\n') do |path|
        EnvLoader.load(path)
        assert_equal "hello world", ENV["FOO"]
      end
    end

    def test_load_single_quoted
      with_env_file("FOO='hello world'\n") do |path|
        EnvLoader.load(path)
        assert_equal "hello world", ENV["FOO"]
      end
    end

    def test_load_single_quoted_preserves_escapes
      with_env_file("FOO='hello\\nworld'\n") do |path|
        EnvLoader.load(path)
        assert_equal 'hello\nworld', ENV["FOO"]
      end
    end

    def test_load_double_quoted_escapes
      with_env_file("FOO=\"hello\\nworld\\ttab\"\n") do |path|
        EnvLoader.load(path)
        assert_equal "hello\nworld\ttab", ENV["FOO"]
      end
    end

    def test_load_escaped_double_quote
      with_env_file("FOO=\"hello \\\"world\\\"\"\n") do |path|
        EnvLoader.load(path)
        assert_equal 'hello "world"', ENV["FOO"]
      end
    end

    def test_load_skips_comments
      with_env_file("# this is a comment\nFOO=bar\n") do |path|
        EnvLoader.load(path)
        assert_equal "bar", ENV["FOO"]
        refute ENV.key?("#")
      end
    end

    def test_load_skips_blank_lines
      with_env_file("\n\nFOO=bar\n\n") do |path|
        EnvLoader.load(path)
        assert_equal "bar", ENV["FOO"]
      end
    end

    def test_load_export_prefix
      with_env_file("export FOO=bar\n") do |path|
        EnvLoader.load(path)
        assert_equal "bar", ENV["FOO"]
      end
    end

    def test_load_inline_comment
      with_env_file("FOO=bar # this is a comment\n") do |path|
        EnvLoader.load(path)
        assert_equal "bar", ENV["FOO"]
      end
    end

    def test_load_no_overwrite_by_default
      ENV["FOO"] = "original"
      with_env_file("FOO=new\n") do |path|
        EnvLoader.load(path)
        assert_equal "original", ENV["FOO"]
      end
    end

    def test_load_overwrite
      ENV["FOO"] = "original"
      with_env_file("FOO=new\n") do |path|
        EnvLoader.load(path, overwrite: true)
        assert_equal "new", ENV["FOO"]
      end
    end

    def test_load_returns_path
      with_env_file("FOO=bar\n") do |path|
        result = EnvLoader.load(path)
        assert_equal path, result
      end
    end

    def test_load_raises_on_explicit_missing_file
      assert_raises(EnvLoader::Error) do
        EnvLoader.load("/definitely/not/a/real/.env")
      end
    end

    def test_load_returns_nil_when_auto_detect_finds_nothing
      # Auto-detect with no .env in cwd or ~/.rubot
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          # Make sure ~/.rubot has no .env
          rubot_dir = File.join(File.expand_path("~"), ".rubot")
          backup = Dir.glob(File.join(rubot_dir, ".env*")).map { |f| [ f, File.read(f) ] }
          begin
            backup.each { |f, _| File.delete(f) }
            result = EnvLoader.load
            assert_nil result
          ensure
            backup.each { |f, c| File.write(f, c) }
          end
        end
      end
    end

    def test_load_auto_detects_env_in_current_dir
      with_env_file("AUTO_DETECT=yes\n", filename: ".env") do |path|
        Dir.chdir(File.dirname(path)) do
          EnvLoader.load
          assert_equal "yes", ENV["AUTO_DETECT"]
        end
      end
    end

    def test_load_auto_detects_env_in_rubot_dir
      rubot_dir = File.join(File.expand_path("~"), ".rubot")
      FileUtils.mkdir_p(rubot_dir)
      env_path = File.join(rubot_dir, ".env")
      begin
        File.write(env_path, "RUBOT_AUTO=yes\n")
        EnvLoader.load
        assert_equal "yes", ENV["RUBOT_AUTO"]
      ensure
        File.delete(env_path) if File.exist?(env_path)
      end
    end

    def test_parse_string_content
      content = "FOO=bar\nBAZ=\"qux\"\n"
      EnvLoader.parse(content, overwrite: true)
      assert_equal "bar", ENV["FOO"]
      assert_equal "qux", ENV["BAZ"]
    end

    def test_valid_keys
      assert EnvLoader.send(:valid_key?, "FOO")
      assert EnvLoader.send(:valid_key?, "_FOO")
      assert EnvLoader.send(:valid_key?, "FOO_BAR_123")
      refute EnvLoader.send(:valid_key?, "")
      refute EnvLoader.send(:valid_key?, "123FOO")
      refute EnvLoader.send(:valid_key?, "FOO-BAR")
      refute EnvLoader.send(:valid_key?, "FOO BAR")
    end

    def test_unterminated_double_quote_raises
      with_env_file("FOO=\"unterminated\n") do |path|
        assert_raises(EnvLoader::ParseError) do
          EnvLoader.load(path)
        end
      end
    end

    def test_unterminated_single_quote_raises
      with_env_file("FOO='unterminated\n") do |path|
        assert_raises(EnvLoader::ParseError) do
          EnvLoader.load(path)
        end
      end
    end

    def test_load_typical_rubot_env
      content = <<~ENV
        # Rubot configuration
        RUBOT_API_KEY=sk-test-key-12345
        RUBOT_API_BASE=https://api.example.com/v1

        # Telegram
        export TELEGRAM_BOT_TOKEN="123456:ABC-DEF"
      ENV

      with_env_file(content) do |path|
        EnvLoader.load(path, overwrite: true)
        assert_equal "sk-test-key-12345", ENV["RUBOT_API_KEY"]
        assert_equal "https://api.example.com/v1", ENV["RUBOT_API_BASE"]
        assert_equal "123456:ABC-DEF", ENV["TELEGRAM_BOT_TOKEN"]
      end
    end

    private

    def with_env_file(content, filename: ".env.test")
      Dir.mktmpdir do |dir|
        path = File.join(dir, filename)
        File.write(path, content)
        yield path
      end
    end
  end
end
