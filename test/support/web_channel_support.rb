# frozen_string_literal: true

require "test_helper"
require "rubot"

module Rubot
  module Web
    # What every web channel test needs: the throwaway ~/.rubot a channel is
    # built on, the fakes it is handed (responses, requests, clocks, pools) and
    # the helpers that read a page back as rows of text.
    module WebChannelSupport
      def feed_subagent(turn, info)
        turn.subagent(info)
        turn.subagent_item(info)
      end
      class FakeClock
        def initialize(now = 100.0)
          @now = now
        end

        def call
          @now
        end

        def advance(seconds)
          @now += seconds
        end
      end
      def build(clock = FakeClock.new)
        Turn.new(id: "t1", session_id: "s1", clock: clock)
      end
      class NamingProvider
        attr_reader :calls

        def initialize(title: "Undangan pernikahan")
          @title = title
          @calls = []
        end

        def chat(messages, tools: nil)
          @calls << messages
          if messages.any? { |msg| msg["content"].to_s.include?("You name conversations") }
            { "content" => @title }
          else
            { "content" => "Siap, undangannya sudah saya susun." }
          end
        end

        def chat_stream(messages, tools: nil, on_retry: nil, &_on_chunk)
          chat(messages, tools: tools)
        end

        def naming_calls
          @calls.count { |messages| messages.any? { |msg| msg["content"].to_s.include?("You name conversations") } }
        end
      end
      def render_page(live_turn: nil, persona_prompt: "", persona_tool_output: "verbose")
        View.render("index",
                    personas: [], groups: { pinned: [], recent: [], page: 1, pages: 1, recent_total: 0, pinned_limit: 10, current: "web_rubot" },
                    slug: "rubot", persona_label: "Rubot", persona_emoji: "🤖",
                    persona_prompt: persona_prompt,
                    persona_model: "m", session_id: "web_rubot",
                    persona_model_value: "", model_choices: [],
                    session_model: "", session_thinking: "medium", persona_thinking: "medium",
                    persona_tool_output: persona_tool_output,
                    skill_choices: [], skills_dir: "~/.rubot/skills",
                    session_short: "web_rubot", session_label: "Sesi baru",
                    document_title: "rubot · Rubot", live_turn: live_turn,
                    live_prompt_shown: false, token_query: "",
                    page: { entries: [], more: false, before: 0 }, older_url: "",
                    usage: { cost: "—", cache: "—", ctx: "—" },
                    usage_facts: { model: "m · openai", cost: "—", breakdown: "",
                                   requests: "0", messages: "0", tokens_in: "0",
                                   tokens_out: "0", reasoning: "", cache: "—",
                                   cache_history: "", re_read: "0", saved: "", ctx: "—" })
      end
      class FakeResponse
        attr_accessor :body, :status
        attr_reader :headers

        def initialize
          @headers = {}
          @status = 200
          @body = ""
        end

        def []=(key, value)
          @headers[key] = value
        end
      end
      class FakeRequest
        attr_reader :path, :request_method, :query, :header

        def initialize(path, method: "GET", query: {}, body: "")
          @path = path
          @request_method = method
          @query = query
          @header = {}
          @body = body
        end

        # A group of checkboxes posts the same key more than once, so the raw
        # body is the only place every value still exists; #query keeps just the
        # last of them.
        def body
          @body.to_s
        end

        def request_uri
          URI.parse("http://localhost#{@path}")
        end

        # WEBrick answers a missing header field with nil, and a redirect reads
        # the token cookie through it.
        def [](_key)
          @header[_key] || @header[_key.to_s]
        end
      end
      class FakeToolAgent
        def initialize(*tools)
          @tools = Rubot::Tools::Registry.new
          tools.each { |tool| @tools.register(tool) }
        end

        attr_reader :tools
      end
      class RecordingCronSession
        attr_reader :calls, :titles

        def initialize(reply: "done")
          @reply = reply
          @calls = []
          @titles = []
        end

        def process_cron(text, fresh: false)
          @calls << { text: text, fresh: fresh }
          @reply
        end

        def set_session_title(title)
          @titles << title
          title
        end
      end
      class FakeWorkspacePool
        def initialize(workspace)
          @workspace = workspace
        end

        def workspace_for_session(_sid)
          @workspace
        end
      end
      def setup
        @fixtures = []
      end
      def teardown
        Rubot::Session.store&.close
        Rubot::Session.store = nil
        Array(@fixtures).each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
      end
      def record_reports(channel)
        said = []
        channel.define_singleton_method(:session_for) do |_sid|
          fake = Object.new
          fake.define_singleton_method(:process_background) do |text, label: "", fresh: false, &chunk|
            said << { text: text, label: label, fresh: fresh }
            chunk&.call("Siap, ")
            chunk&.call("hasilnya kubaca.")
            "Siap, hasilnya kubaca."
          end
          fake.define_singleton_method(:tools) do
            tools = Object.new
            tools.define_singleton_method(:get) { |_name| nil }
            tools
          end
          fake
        end
        said
      end
      class FakeDelegateHandle
        attr_reader :session_id

        def initialize(answer)
          @answer = answer
          @session_id = "web_rubot~sub-r1"
        end

        def process(_task, **_callbacks)
          @answer
        end
      end
      def channel_with_sessions(personas:, sessions: {}, titles: {})
        dir = Dir.mktmpdir("rubot-web-sessions")
        @fixtures << dir
        workspace = File.join(dir, "workspace")
        FileUtils.mkdir_p(File.join(dir, "sessions"))
        FileUtils.mkdir_p(workspace)

        File.write(File.join(dir, "personas.json"), JSON.generate(personas))
        sessions.each do |id, prompt|
          data = {
            "id" => id,
            "updated_at" => Time.now.utc.iso8601,
            "messages" => [
              { "role" => "user", "content" => prompt },
              { "role" => "assistant", "content" => "Siap." }
            ]
          }
          data["title"] = titles[id] if titles[id]
          File.write(File.join(dir, "sessions", "#{id}.json"), JSON.generate(data))
        end

        config = Rubot::Config.from_data(
          { "agents" => { "defaults" => { "workspace" => workspace } } },
          config_path: File.join(dir, "config.yml")
        )

        channel = Rubot::Channels::Web.new(channel_config: {})
        channel.instance_variable_set(:@app_config, config)
        channel
      end
      def channel_with_archive(personas:, messages:, titles: {})
        dir = Dir.mktmpdir("rubot-web-archive")
        @fixtures << dir
        workspace = File.join(dir, "workspace")
        FileUtils.mkdir_p(File.join(dir, "sessions"))
        FileUtils.mkdir_p(workspace)

        File.write(File.join(dir, "personas.json"), JSON.generate(personas))

        store = Rubot::Store.new(Rubot::Store.path_for(File.join(dir, "sessions")))
        messages.each do |sid, rows|
          store.append_messages(sid, rows.map.with_index do |(role, text), offset|
            { "role" => role, "content" => text,
              "timestamp" => (Time.utc(2026, 11, 10, 8, 0) + offset).iso8601 }
          end)
          store.upsert_session(id: sid, title: titles.fetch(sid, rows.first.last),
                               updated_at: "2026-11-10T08:00:00Z")
        end
        Rubot::Session.store = store

        config = Rubot::Config.from_data(
          { "agents" => { "defaults" => { "workspace" => workspace } } },
          config_path: File.join(dir, "config.yml")
        )

        channel = Rubot::Channels::Web.new(channel_config: {})
        channel.instance_variable_set(:@app_config, config)
        channel
      end
      def write_long_session(channel, sid, pairs)
        dir = channel.instance_variable_get(:@app_config).sessions_dir
        messages = (1..pairs).flat_map do |i|
          [ { "role" => "user", "content" => "pesan #{i}" },
            { "role" => "assistant", "content" => "balasan #{i}" } ]
        end

        File.write(File.join(dir, "#{sid}.json"),
                   JSON.generate({ "id" => sid, "updated_at" => Time.now.utc.iso8601,
                                   "messages" => messages }))
      end
      # How many transcript rows a page stands for: the unit the page is cut by
      # (see HistoryView::HISTORY_PAGE_MESSAGES).
      def spanned_messages(page)
        page[:entries].sum { |entry| entry[:last].to_i - entry[:idx].to_i + 1 }
      end
      # A prompt and a turn of several messages: the shapes a cursor can be
      # mistaken between, and the shape a real conversation has.
      def write_multi_message_session(channel, sid, prompts)
        dir = channel.instance_variable_get(:@app_config).sessions_dir
        messages = (1..prompts).flat_map do |i|
          [ { "role" => "user", "content" => "pesan #{i}" } ] +
            Array.new(3) { |k| { "role" => "assistant", "content" => "balasan #{i}.#{k + 1}" } }
        end
        File.write(File.join(dir, "#{sid}.json"),
                   JSON.generate({ "id" => sid, "updated_at" => Time.now.utc.iso8601,
                                   "messages" => messages }))
      end
      def kinds(turn)
        turn.items.map { |item| item[:kind] }
      end
      def texts(turn)
        turn.items.select { |item| item[:kind] == :text }.map { |item| item[:text] }
      end
      def settings_page_html
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        res = FakeResponse.new
        channel.send(:render_settings, res, FakeRequest.new("/settings"))
        res.body
      end
      def persona_form_request(path, fields)
        pairs = fields.flat_map do |key, value|
          Array(value).map { |item| [ key.to_s, item.to_s ] }
        end
        body = pairs.map do |key, value|
          "#{URI.encode_www_form_component(key)}=#{URI.encode_www_form_component(value)}"
        end.join("&")
        FakeRequest.new(path, method: "POST", query: pairs.to_h, body: body)
      end
      def channel_with_skills(personas: {}, skills: {})
        dir = Dir.mktmpdir("rubot-web-skills")
        @fixtures << dir
        workspace = File.join(dir, "workspace")
        catalog = File.join(dir, "catalog")
        FileUtils.mkdir_p(File.join(dir, "sessions"))
        FileUtils.mkdir_p(workspace)
        skills.each do |name, description|
          skill_dir = File.join(catalog, "skills", name)
          FileUtils.mkdir_p(skill_dir)
          File.write(File.join(skill_dir, "SKILL.md"),
                     "---\nname: #{name}\ndescription: #{description}\n---\n\nIsi.\n")
        end
        File.write(File.join(dir, "personas.json"), JSON.generate(personas))

        config = Rubot::Config.from_data(
          { "agents" => { "defaults" => { "workspace" => workspace,
                                          "skills_workspace" => catalog } } },
          config_path: File.join(dir, "config.yml")
        )

        channel = Rubot::Channels::Web.new(channel_config: {})
        channel.instance_variable_set(:@app_config, config)
        channel
      end
      def edit_request(values)
        request = Object.new
        request.define_singleton_method(:query) { values }
        request.define_singleton_method(:[]) { |_key| nil }
        request
      end
      def gate_request(path, query_string: "", accept: "text/html", htmx: false, method: "GET")
        query = URI.decode_www_form(query_string).to_h
        request = Object.new
        request.define_singleton_method(:path) { path }
        request.define_singleton_method(:request_method) { method }
        request.define_singleton_method(:query) { query }
        request.define_singleton_method(:query_string) { query_string }
        request.define_singleton_method(:cookies) { [] }
        request.define_singleton_method(:[]) do |key|
          case key.to_s
          when "Accept" then accept
          when "HX-Request" then htmx ? "true" : nil
          end
        end
        request
      end
      def stub_title_writer(channel)
        store = Rubot::Session.store
        channel.define_singleton_method(:session_for) do |sid|
          Object.new.tap do |handle|
            handle.define_singleton_method(:set_session_title) do |title|
              store.upsert_session(id: sid, title: title)
            end
          end
        end
      end
      def stored_title(sid)
        Rubot::Session.store.sidebar(limit: 50).find { |row| row[:id] == sid }&.fetch(:title)
      end
      def form_post(fields)
        request = Struct.new(:query) do
          def [](key) = key == "HX-Request" ? "true" : nil
        end
        request.new(fields)
      end
      def req_with_path(request, path, method)
        request.define_singleton_method(:path) { path }
        request.define_singleton_method(:request_method) { method }
        request
      end
      def write_two_reads(channel)
        sid = "web_rubot"
        calls = %w[a.rb b.rb].each_with_index.map do |path, index|
          { "id" => "c#{index + 1}",
            "function" => { "name" => "file_ops",
                            "arguments" => JSON.generate({ "path" => path }) } }
        end
        write_messages(channel, sid, [
                         { "role" => "user", "content" => "Cek dua file" },
                         { "role" => "assistant", "content" => "", "tool_calls" => calls },
                         { "role" => "tool", "tool_call_id" => "c1", "content" => "isi a" },
                         { "role" => "tool", "tool_call_id" => "c2", "content" => "isi b" },
                         { "role" => "assistant", "content" => "Dua-duanya oke." }
                       ])
        sid
      end
      def write_two_rounds(channel)
        sid = "web_rubot"
        call = lambda do |id, path|
          { "role" => "assistant", "content" => "",
            "tool_calls" => [ { "id" => id,
                                "function" => { "name" => "file_ops",
                                                "arguments" => JSON.generate({ "path" => path }) } } ] }
        end
        write_messages(channel, sid, [
                         { "role" => "user", "content" => "Cek dua file" },
                         call.call("c1", "a.rb"),
                         { "role" => "tool", "tool_call_id" => "c1", "content" => "isi a" },
                         call.call("c2", "b.rb"),
                         { "role" => "tool", "tool_call_id" => "c2", "content" => "isi b" },
                         { "role" => "assistant", "content" => "Dua-duanya oke." }
                       ])
        sid
      end
      def rem(value)
        value.to_s.delete("rem").to_f
      end
      def turn_request(message)
        Struct.new(:query, :query_string) do
          def content_type = "application/x-www-form-urlencoded"
          def body = ""
          def [](_key) = nil
        end.new({ "message" => message }, "")
      end
      def write_attachment(channel, sid, basename, body)
        name = "a" * 32 + "-#{File.basename(basename, File.extname(basename))}#{File.extname(basename)}"
        dir = channel.send(:attachments_dir, sid)
        FileUtils.mkdir_p(dir)
        File.binwrite(File.join(dir, name), body)
        name
      end
      def write_picture(channel, sid, basename = "shot.png")
        write_attachment(channel, sid, basename, png_bytes)
      end
      def write_messages(channel, sid, messages)
        dir = channel.instance_variable_get(:@app_config).sessions_dir
        File.write(File.join(dir, "#{sid}.json"),
                   JSON.generate({ "id" => sid, "updated_at" => Time.now.utc.iso8601,
                                   "messages" => messages }))
      end
      def png_bytes
        "\x89PNG\r\n\x1A\n".b + ("\x00".b * 64)
      end
    end
  end
end
