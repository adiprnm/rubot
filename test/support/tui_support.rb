# frozen_string_literal: true

require "stringio"
require "test_helper"
require "rubot"

module Rubot
  # What every TUI test needs: the off-screen App the repl is driven through
  # (build_repl), the stubs it is handed, and the views a resume or a model
  # list is read back through.
  module TuiSupport
    StubInfo = Struct.new(:provider, :model, :tools, :name)
    def stub_agent
      agent = Object.new
      def agent.startup_info
        { provider: "openai", model: "gpt-test", tools: 3 }
      end

      # Learning runs after the answer is on screen; a stub that cannot do it
      # would turn every turn into an error row and hide what is being tested.
      def agent.flush_learning
        nil
      end

      # A launch has spent nothing yet but already carries a system prompt.
      def agent.usage_report
        { requests: 0, prompt_tokens: 0, cache_hit_rate: 0.0,
          context_used: 3_100, context_window: 128_000, context_percent: 2.4,
          cost: { "total" => 0.0 } }
      end

      agent
    end
    def build_repl
      repl = TUI.new(stub_agent)
      repl.build_ui
      repl.paint_banner
      repl
    end
    # Stub that remembers auto mode, the way the real handle does.
    def auto_agent
      agent = stub_agent
      def agent.auto_approve?
        @auto == true
      end

      def agent.set_auto_approve(value)
        @auto = value
      end

      def agent.startup_info
        info = { provider: "openai", model: "gpt-test", tools: 3 }
        info[:auto_approve] = true if auto_approve?
        info
      end

      agent
    end
    def teardown
      FileUtils.rm_f(TUI::HISTORY_FILE)
    end
    # render_lines keeps per-segment SGR resets between differently styled
    # runs; strip them before string matching.
    def plain(lines)
      lines.map { |l| l.gsub(/\e\[[0-9;?]*[a-zA-Z]/, "").gsub(/\e\]8;;\e\\/, "") }
    end
    # A temporary tree with a nested file, used by the @-mention tests.
    def with_files
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "README.md"), "")
        File.write(File.join(dir, "lib", "app.rb"), "")
        yield TUI::PromptInput.new([], TUI::COMPLETABLE, files: TUI::FileIndex.new(dir))
      end
    end
    # Run one turn whose tool writes `after` into `path`, the way the agent
    # loop does it: on_tool_call fires before the write, on_tool_result after,
    # and both carry the file's before/after text. The TUI never reads the file
    # itself — that raced the tool, so a delete's diff came out empty.
    def run_file_tool(repl, operation:, path:, after:, snapshot_after_write: false)
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:process) do |_message, on_tool_call: nil, on_tool_result: nil, **_opts, &_blk|
        before = File.exist?(path) ? File.read(path, encoding: "UTF-8") : nil
        args = { "operation" => operation, "path" => path }
        on_tool_call&.call("file_ops", args, { path: path, expanded: File.expand_path(path), before: before })
        # nil after means the call removed the file, as `delete` does.
        after.nil? ? FileUtils.rm_f(path) : File.write(path, after)
        # The before-content is the one taken before the write; reading it now
        # (snapshot_after_write) is what a racing caller would see.
        seen = snapshot_after_write && File.exist?(path) ? File.read(path, encoding: "UTF-8") : before
        ui_diff = { "path" => path, "before" => seen, "after" => after }
        on_tool_result&.call("file_ops", "ok", ui_diff)
        "done"
      end
      agent.define_singleton_method(:flush_learning) { nil }
      agent.define_singleton_method(:usage_report) { nil }

      repl.process_message("edit it")
      repl.pump
      repl
    end
    def entry_texts(repl)
      repl.instance_variable_get(:@log).instance_variable_get(:@entries)
          .map { |entry| entry.map(&:first).join }
    end
    def git_texts(rows)
      rows.map { |segments| segments.map(&:first).join }
    end
    # The wrapped rows of one markdown list, each as the plain text the log
    # paints, with the entry indent already applied.
    def list_rows(markdown)
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 24, 14))
      view.add_entry(TUI::Markdown.to_segments(markdown), keep_leading: true, indent: 2)
      rows = view.instance_variable_get(:@lines).map { |row| row.map(&:first).join }
      rows.reject(&:empty?)
    end
    # Column indexes of `row` painted with `style`.
    # The log keeps its scroll offset private; the scrollbar tests read it
    # the same way the other view tests do.
    def scroll_y(view)
      view.instance_variable_get(:@scroll_y)
    end
    def styled_columns(canvas, row, style)
      sid = ::TUI::Style.id(style)
      styles = canvas.instance_variable_get(:@styles)[row]
      styles.each_index.select { |i| styles[i] == sid }
    end
    class ResumeSessionView
      attr_accessor :id

      def initialize(id)
        @id = id
      end
    end
    class ResumeConfigView
      attr_reader :workspace, :sessions_dir, :sessions_cwd

      def initialize(workspace)
        @workspace = workspace
        # Central storage plus the directory sessions are tagged with; the real
        # Config keeps them apart, the fake keeps both inside the tmpdir.
        @sessions_dir = File.join(workspace, "sessions")
        @sessions_cwd = workspace
      end
    end
    class ResumeAgent
      attr_reader :config, :session, :switched

      def initialize(workspace, session_id: "default")
        @config = ResumeConfigView.new(workspace)
        @session = ResumeSessionView.new(session_id)
        @switched = []
      end

      def startup_info
        { provider: "openai", model: "gpt-test", tools: 3 }
      end

      def active_model_name
        "gpt-test"
      end

      def switch_session(name)
        @switched << name.to_s
        @session = ResumeSessionView.new(name.to_s)
      end

      def clear_session; end

      def usage_report
        nil
      end
    end
    def saved_session(workspace, id, content, updated_at: Time.now.iso8601, messages: nil, cwd: :default)
      dir = File.join(workspace, "sessions")
      FileUtils.mkdir_p(dir)
      messages ||= [
        { "role" => "user", "content" => content },
        { "role" => "assistant", "content" => "answer to #{content}" }
      ]
      payload = {
        "id" => id,
        "updated_at" => updated_at,
        "messages" => messages
      }
      # Sessions are tagged with the directory they were launched from; :default
      # means "this workspace", nil means "no origin at all".
      tag = cwd == :default ? workspace : cwd
      payload["cwd"] = tag if tag
      File.write(File.join(dir, "#{id}.json"), JSON.pretty_generate(payload))
    end
    def build_resume_repl(workspace)
      repl = TUI.new(ResumeAgent.new(workspace))
      repl.build_ui
      repl.paint_banner
      repl
    end
    class ModelsConfigView
      def initialize(models)
        @models = models
      end

      def models
        @models
      end

      def model_entry_by_name(name)
        @models.find { |model| model["name"] == name }
      end
    end
    class ModelsSessionView
      attr_accessor :model_override

      def initialize
        @model_override = nil
      end

      def id
        "default"
      end
    end
    class ModelsProviderView
      def name
        "openai"
      end
    end
    # An agent that knows a provider catalog, so /models has something to
    # list that config.yml does not mention.
    class ModelsAgent
      attr_reader :config, :session, :provider, :used

      def initialize(models:, catalog:, active: "gpt-test")
        @config = ModelsConfigView.new(models)
        @session = ModelsSessionView.new
        @provider = ModelsProviderView.new
        @catalog = catalog
        @active = active
        @used = []
      end

      def startup_info
        { provider: "openai", model: @active, tools: 3 }
      end

      def provider_models
        @catalog
      end

      def active_model_name
        @active
      end

      def use_model(name)
        @used << name.to_s
        @active = name.to_s
        @session.model_override = name.to_s
        name.to_s
      end

      def usage_report
        nil
      end
    end
    def build_models_repl(models: [], catalog: [], active: "gpt-test")
      repl = TUI.new(ModelsAgent.new(models: models, catalog: catalog, active: active))
      repl.build_ui
      repl.paint_banner
      repl
    end
    # The clipboard is read through desktop tools, which no test can rely on;
    # what the paste key does with what it finds is what is checked here.
    def stub_clipboard(images: [], text: nil)
      originals = { capture_all: ClipboardImage.method(:capture_all), text: ClipboardImage.method(:text) }
      ClipboardImage.define_singleton_method(:capture_all) { |dir: nil| images }
      ClipboardImage.define_singleton_method(:text) { text }
      yield
    ensure
      originals.each { |name, method| ClipboardImage.define_singleton_method(name, method) }
    end
    # A PNG header is enough for ImageInfo to read the dimensions.
    def png_file(dir, width: 40, height: 30, name: "shot.png")
      ihdr = [ width, height, 8, 2, 0, 0, 0 ].pack("N2C5")
      path = File.join(dir, name)
      File.binwrite(path, "\x89PNG\r\n\x1A\n".b + [ 13 ].pack("N") + "IHDR" + ihdr + [ 0 ].pack("N"))
      path
    end
    def long_text(lines)
      (1..lines).map { |i| "line #{i} of a pasted passage" }.join("\n")
    end
    # The transcript as plain text, one string per log entry.
    def log_texts(repl)
      log = repl.instance_variable_get(:@log)
      log.instance_variable_get(:@entries).map { |segments| segments.map(&:first).join }
    end
    # Pretend the thought has been running for `seconds`.
    def age_thinking(repl, seconds)
      repl.instance_variable_set(:@thinking_started_at, repl.monotonic_now - seconds)
    end
  end
end
