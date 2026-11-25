# frozen_string_literal: true

module Rubot
  class TUI
    # The slash commands, and the lookups behind the two that need one: what
    # /resume and /search pick from, and which model or skill a name refers to.
    #
    # Each command answers through say/say_text and returns nothing; the run
    # that carries it lives in the worker, so a command typed mid-turn is
    # answered next to the turn instead of after it.
    module Commands
      private

      def handle_command(input)
        @command_output = []
        # A command that brings its own blank line (a list, or a wiped
        # transcript) does not get one from the flush.
        @command_owns_blank = false
        parts = input.split
        cmd = parts.first.downcase

        case cmd
        when "/help" then command_help
        when "/clear" then command_clear
        when "/new" then command_new
        when "/stop" then command_stop
        when "/compact" then command_compact
        when "/repin" then command_repin
        when "/session" then command_session(parts[1])
        when "/resume" then handle_resume(parts[1])
        when "/search" then handle_search(parts[1..].join(" "))
        when "/info" then command_info
        when "/context" then command_context
        when "/usage" then command_usage
        when "/timing" then command_timing
        when "/models" then handle_models_command(parts[1])
        when "/model" then command_model
        when "/use-model" then handle_use_model(parts[1])
        when "/tools" then command_tools
        when "/soul" then command_soul
        when "/memory" then command_memory
        when "/agents" then command_agents
        when "/delegates" then handle_delegates_command
        when "/cron" then command_cron
        when "/web-restart" then restart_web_channel
        when "/auto" then handle_auto_command(parts[1])
        when "/stream" then command_stream(parts[1])
        when "/use" then handle_use_skill(parts[1])
        when "/unuse" then command_unuse
        when "/quit", "/exit" then command_quit
        else command_unknown(cmd)
        end
      rescue StandardError => e
        say("#{e.class}: #{e.message}", :err)
        raise if Rubot.debug?
      ensure
        flush_command_output
      end

      # One method per command: the dispatch above is the list, and the body
      # that runs is one of these. They share what handle_command sets up (the
      # output buffer, the blank-line flag it owns) and the say/say_text pair
      # every command answers through.
      def command_help
        blank
        say(I18n.t("tui.commands.available"), :info)
        COMMANDS.each_key do |syntax|
          say_text(format("  %-20s %s", syntax, I18n.t("tui.help.cmd.#{help_slug(syntax)}")))
        end
        blank
        say(I18n.t("tui.commands.keys"), :info)
        KEYS.each_key do |keys|
          say_text(format("  %-20s %s", keys, I18n.t("tui.help.key.#{help_slug(keys)}")))
        end
        blank
      end

      # The dictionary name of one /help row: the command or the keystroke the
      # reader sees, spelled out (an arrow becomes its direction), so the table
      # in tui.rb and the dictionary cannot be keyed by two different words.
      def help_slug(text)
        text.to_s.downcase
            .gsub("↑", "up").gsub("↓", "down")
            .gsub("←", "left").gsub("→", "right")
            .gsub(/[^a-z0-9]+/, "_")
            .gsub(/\A_+|_+\z/, "")
      end

      # The seam a test holds the two /help tables against the dictionary with:
      # the row a reader sees decides the key, so the check is this method and
      # not a second copy of the spelling rules. Everything else here stays
      # private.
      public :help_slug

      def command_clear
        agent.clear_session
        @events << [ :reset_turn_totals ]
        say(I18n.t("tui.session.cleared"), :ok)
        refresh_usage
      end

      def command_new
        # Silent restart: wipe the screen and start a fresh session.
        @command_owns_blank = true
        agent.clear_session
        @events << [ :clear_log ]
        refresh_status
      end

      def command_stop
        agent.cancel!
        say(I18n.t("tui.commands.stop_requested"), :ok)
      end

      def command_compact
        result = agent.compact_session
        if result
          say(I18n.t("compaction.complete"), :ok)
          say_text(I18n.t("compaction.summarized", count: result[:summarized_messages]))
          say_text(I18n.t("compaction.kept", count: result[:kept_messages]))
          say_text(I18n.t("compaction.context", before: result[:context_before], after: result[:context_after]))
        else
          say(I18n.t("compaction.empty"), :info)
        end
        refresh_usage
      end

      def command_repin
        # The prompt is pinned so the cached prefix survives a memory write, so
        # a line added to MEMORY.md mid-session is invisible until the epoch
        # moves. This is the door, and the price is on the tin: one request paid
        # in full, because the prefix moves with the prompt.
        if agent.repin_system_prompt
          say(I18n.t("tui.prompt.repinned"), :ok)
          say_text(I18n.t("tui.prompt.repinned_detail"))
          say_text(I18n.t("tui.prompt.repinned_cost"))
        else
          say(I18n.t("tui.prompt.not_pinned"), :info)
        end
      end

      def command_session(name)
        if name
          switch_session(name)
          say(I18n.t("tui.session.switched", name: name), :ok)
          refresh_status
          refresh_usage
        else
          say(I18n.t("tui.session.current", id: agent.session.id), :info)
          say_text(I18n.t("tui.session.model", model: agent.active_model_name))
          say_text(I18n.t("tui.session.browse_hint"))
        end
      end

      def command_info
        say(I18n.t("tui.info.title"), :info)
        agent.startup_info.each { |k, v| say_text("#{k}: #{v}") }
      end

      def command_context
        blank
        # Mid-turn the agent is busy with the answer, so the report it last
        # published is what there is to show — the same numbers the footer
        # is moving.
        report = @live_report || agent.usage_report
        say_text(Rubot::UsageReport.render(report))
        say_text(I18n.t("tui.context.live")) if @live_report
        blank
      end

      def command_usage
        blank
        say_text(Rubot::OpencodeUsageReport.render(agent.opencode_usage))
        blank
      end

      def command_timing
        blank
        say_text(Rubot::Timing.report)
        blank
      end

      def command_model
        active = agent.active_model_name
        entry = agent.config.model_entry_by_name(active) || agent.config.active_model_entry
        say(I18n.t("tui.model.current", model: active, id: entry["model"]), :info)
        say(I18n.t("tui.model.override"), :warn) if agent.session.model_override
      end

      def command_tools
        say(I18n.t("tui.tools.title"), :info)
        agent.tools.all.each do |tool|
          say_text("  - #{tool.name}: #{tool.description.lines.first.strip}")
        end
      end

      def command_soul
        if agent.soul.enabled?
          say(I18n.t("tui.soul.title"), :info)
          say_text(agent.soul.read, :text)
        else
          say(I18n.t("tui.soul.none"), :warn)
        end
      end

      def command_memory
        if agent.memory.enabled?
          memory = agent.memory
          if memory.respond_to?(:global_path)
            say(I18n.t("tui.memory.global", path: memory.global_path), :info)
            say(I18n.t("tui.memory.workspace", path: memory.workspace_path), :info)
          else
            say(I18n.t("tui.memory.title"), :info)
          end
          say_text(memory.read, :text)
        else
          say(I18n.t("tui.memory.none"), :warn)
        end
      end

      def command_agents
        if agent.agents_file.enabled?
          say(I18n.t("tui.agents.title"), :info)
          say_text(agent.agents_file.raw, :text)
        else
          say(I18n.t("tui.agents.none"), :warn)
        end
      end

      def command_cron
        cron_tool = agent.tools.get("cron")
        if cron_tool
          say_text(cron_tool.execute({ "operation" => "list" }).to_s, :text)
        else
          say(I18n.t("tui.cron.none"), :warn)
        end
      end

      def command_stream(argument)
        @stream = argument.downcase == "on" if argument
        state = I18n.t(@stream ? "tui.stream.on" : "tui.stream.off")
        say(I18n.t("tui.stream.state", state: state), :info)
      end

      def command_unuse
        if agent.session.forced_skill
          agent.session.forced_skill = nil
          agent.session.save! if agent.session.respond_to?(:save!)
          say(I18n.t("tui.skill.cleared"), :ok)
        else
          say(I18n.t("tui.skill.none"), :info)
        end
      end

      def command_quit
        @app ? @app.quit : exit
      end

      def command_unknown(cmd)
        say(I18n.t("tui.commands.unknown", command: cmd), :err)
        say_text(I18n.t("tui.commands.unknown_hint"))
      end

      # /auto with no argument flips the current mode, so the common case is one
      # word. The choice is persisted by the agent (config.yml), which is why the
      # next launch starts the same way.
      # The script that owns the web channel's process: stopping the server and
      # starting it again, with the "did it actually come up" check. Kept in a
      # method of its own so a test can point it at a stub instead of taking the
      # real listener down.
      def web_restart_command
        [ RbConfig.ruby, File.expand_path("../../bin/web-restart", __dir__) ]
      end

      def restart_web_channel
        output, status = Open3.capture2e(*web_restart_command)
        if status.success?
          say(I18n.t("tui.web.restarted"), :ok)
          # The script reports one line on success: the pid and the address.
          line = output.lines.map(&:strip).reject(&:empty?).last
          say_text(line) if line
        else
          say(I18n.t("tui.web.restart_failed"), :err)
          output.lines.map(&:strip).reject(&:empty?).last(3).each { |line| say_text(line) }
        end
      end

      # The personas a lead agent can hand work to. Read fresh from the store so
      # a persona created after launch shows up. Says plainly when delegation is
      # off, since listing targets that cannot be used would be misleading.
      def handle_delegates_command
        config = agent.config
        unless config.respond_to?(:delegation_enabled?) && config.delegation_enabled?
          say(I18n.t("tui.delegates.off"), :warn)
          return
        end

        store = Rubot::PersonaStore.from_config(config, dir: File.dirname(config.personas_file))
        specialists = store.specialists
        if specialists.empty?
          say(I18n.t("tui.delegates.none"), :warn)
          return
        end

        say(I18n.t("tui.delegates.title", count: specialists.size), :info)
        specialists.each do |slug, persona|
          model = persona.model.to_s
          label = "#{persona.emoji_or} #{persona.label} (#{slug})"
          label += " · #{model}" unless model.empty?
          say_text("  - #{label}")
        end
      rescue StandardError => e
        say(I18n.t("tui.delegates.failed", error: "#{e.class}: #{e.message}"), :err)
      end

      def handle_auto_command(argument)
        word = argument.to_s.strip.downcase
        wanted = if word.empty?
          !auto_mode?
        elsif AUTO_TOGGLE.key?(word)
          AUTO_TOGGLE[word]
        end

        if wanted.nil?
          say(I18n.t("tui.auto.usage"), :err)
          return
        end

        agent.set_auto_approve(wanted)
        # Publish the new status row straight away instead of queueing a full
        # /sync: the metrics did not change, only the badge that says the agent
        # has stopped asking.
        info = agent.startup_info
        @events << [ :status_badge, status_badge_text(info) ]
        @events << [ :status_right, status_right_text(info) ]
        if wanted
          # The same amber as the status badge, so the colour means one thing:
          # this agent acts without asking.
          say(I18n.t("tui.auto.on"), :warn)
          say_text(I18n.t("tui.auto.on_detail"))
        else
          say(I18n.t("tui.auto.off"), :info)
        end
      end

      def auto_mode?
        a = agent
        a.respond_to?(:auto_approve?) ? !!a.auto_approve? : false
      rescue StandardError
        false
      end

      def handle_resume(query)
        text = query.to_s.strip
        # /resume all ignores the launch directory: every conversation that was
        # started from some project. Sessions with no recorded origin (Telegram
        # chats, files written before the cwd field existed) are never listed.
        every = text.casecmp?("all")
        text = "" if every
        sessions = resume_entries(all: every)

        if text.empty?
          # Interactively, /resume writes the list into the log; only a plain (piped) REPL
          # has to print the list and take the number on the next line.
          if @tui && !sessions.empty?
            @command_owns_blank = true
            @events << [ :session_list, sessions ]
          else
            list_sessions(sessions)
          end
          return
        end

        entry = find_session(sessions, text)
        # A hidden session (another project, no origin) is still reachable by id
        # when it is named exactly.
        entry ||= Rubot::Session.find(nil, text, dir: sessions_dir)
        unless entry
          say(I18n.t("tui.session.not_found", query: text), :err)
          say_text(I18n.t("tui.session.see_hint"))
          return
        end

        resume_session(entry)
      end

      # Saved conversations the user can resume, newest first. Everything is
      # stored in one directory; the launch directory decides what shows up.
      def resume_entries(all: false)
        entries = Rubot::Session.index(nil, cwd: :all, dir: sessions_dir)
        entries = entries.reject { |entry| entry[:cwd].to_s.empty? }
        return entries if all

        cwd = sessions_cwd.to_s
        return entries if cwd.empty?

        entries.select { |entry| entry[:cwd] == cwd }
      end

      # How many saved conversations belong to other directories. Shown as a hint
      # so a project that has never been used does not look empty.
      def other_dir_sessions
        all = Rubot::Session.index(nil, cwd: :all, dir: sessions_dir)
        all.count { |entry| !entry[:cwd].to_s.empty? && entry[:cwd].to_s != sessions_cwd.to_s }
      rescue StandardError
        0
      end

      def list_sessions(sessions)
        if sessions.empty?
          say(I18n.t("tui.session.none"), :info)
          say_text(I18n.t("tui.session.none_hint"))
          others = other_dir_sessions
          say_text(I18n.t("tui.session.other_dirs", count: others)) if others.positive?
          return
        end

        current = agent.session.id
        blank
        say(I18n.t("tui.session.list_title"), :info)
        sessions.each_with_index do |session, index|
          marker = session[:id] == current ? MARK[:ok] : " "
          say_text(format("  %s %-2d %-28s %4d %-5s · %-10s %s",
                          marker, index + 1, session[:id], session[:messages],
                          I18n.t("tui.session.messages_unit"),
                          relative_time(session[:updated_at]), Rubot::Session.label(session)))
        end
        blank
        say_text(I18n.t("tui.session.resume_hint"))
        others = other_dir_sessions
        say_text(I18n.t("tui.session.other_dirs_more", count: others)) if others.positive?
      end

      # /search asks the archive, not the session on screen: every message ever
      # stored, including the turns a compacted conversation no longer shows the
      # model — which is the reason the archive is kept. The store answers
      # best-first (bm25 over three weighted columns, see Store#search), and each
      # hit names the session it came from because that is what /resume takes.
      def handle_search(query)
        text = query.to_s.strip
        if text.empty?
          say(I18n.t("tui.search.title"), :info)
          say_text(I18n.t("tui.search.hint"))
          return
        end

        store = Rubot::Archive.current
        if store.nil?
          say(I18n.t("tui.search.no_archive"), :warn)
          say_text(I18n.t("tui.search.no_archive_hint"))
          return
        end

        hits = store.search(text, limit: SEARCH_RESULTS)
        if hits.empty?
          say(I18n.t("tui.search.nothing", query: text.inspect), :info)
          return
        end

        blank
        say(I18n.t("tui.search.hits", count: hits.size, query: text.inspect), :info)
        hits.each_with_index do |hit, index|
          say_text(format("  %-2d %-26s %-9s %s", index + 1, hit[:session_id], hit[:role],
                          relative_time(hit[:created_at])))
          # One line per hit: a terminal wraps, and a wrapped snippet would push
          # the next hit away from its own id.
          say_text("     #{snippet_line(hit[:snippet])}")
        end
        blank
        say_text(I18n.t("tui.search.resume_hint"))
      end

      # A snippet arrives with the archive's own newlines and runs of spaces
      # intact, since it is cut from the message as it was written.
      def snippet_line(text)
        collapsed = text.to_s.gsub(/\s+/, " ").strip
        collapsed.length > 120 ? "#{collapsed[0, 119]}…" : collapsed
      end

      # Only ids that are actually on disk resolve, which also keeps a crafted
      # argument from escaping the sessions directory.
      def find_session(sessions, query)
        text = query.to_s.strip
        return nil if text.empty?
        return sessions[text.to_i - 1] if text.match?(/\A\d+\z/)

        sessions.find { |session| session[:id] == text }
      end

      def resume_session(entry)
        switch_session(entry[:id])
        messages = Rubot::Session.transcript(nil, entry[:id], dir: sessions_dir)

        # The App thread owns the log, so the whole restored transcript is
        # handed over as one event and laid out there with the live renderer.
        if @tui
          @events << [ :replay_transcript, messages ]
        else
          print_transcript(messages)
        end

        refresh_status
        refresh_usage
      end

      # Plain (piped) REPL: the same entries, without styles. Routed through
      # #emit so it gets the same padding as any other command output.
      def print_transcript(messages)
        Rubot::TUI::Transcript.entries(messages).each do |entry|
          indent = " " * entry[:indent].to_i
          text = entry[:segments].map { |segment| segment[0].to_s }.join
          text.split("\n", -1).each { |line| emit([ [ "#{indent}#{line}", :text ] ]) }
        end
      end

      def relative_time(iso)
        Rubot::TUI::SessionList.age(iso)
      end

      # /models lists the models the provider supports and lets the user pick
      # one for the active session. The list comes from the provider's /models
      # endpoint; config.yml entries the provider does not advertise are added
      # at the end, so a configured model stays selectable.
      def handle_models_command(query = nil)
        entries = provider_model_entries
        if entries.empty?
          say(I18n.t("tui.model.none"), :warn)
          say_text(I18n.t("tui.model.none_hint"))
          return
        end

        filter = query.to_s.strip
        shown = entries.select { |entry| Rubot::TUI::ModelList.matches?(entry, filter) }
        if shown.empty?
          say(I18n.t("tui.model.no_match", filter: filter), :warn)
          return
        end

        if @tui
          @command_owns_blank = true
          @events << [ :model_list, entries, model_list_title(entries), filter ]
        else
          say(I18n.t("tui.model.list_header", provider: provider_name), :info)
          shown.each do |entry|
            marker = entry[:active] ? MARK[:ok] : " "
            label = entry[:label].to_s
            label = "" if label == entry[:id].to_s
            say_text("  #{marker} #{entry[:id]}#{label.empty? ? "" : " (#{label})"}")
          end
        end
      end

      def model_list_title(entries)
        I18n.t("tui.model.list_title", provider: provider_name)
      end

      def provider_name
        agent.provider.name
      rescue StandardError
        I18n.t("tui.model.provider_fallback")
      end

      # The models the provider supports, as picker entries. Each entry has an
      # "id" (what the provider is asked for), a "label" (a friendlier name)
      # and an "active" flag.
      def provider_model_entries
        catalog = provider_catalog_entries
        config_entries = config_model_entries

        known = catalog.map { |model| model["id"] }
        entries = catalog.map do |model|
          { id: model["id"], label: model["name"], active: false }
        end

        # A configured model the provider does not advertise is still usable,
        # so it is listed under its config name.
        config_entries.each do |entry|
          model = entry["model"].to_s
          id = model.include?("/") ? model.split("/").last : model
          next if known.include?(id) || known.include?(entry["name"].to_s)

          entries << { id: entry["name"].to_s, label: model, active: false }
        end

        active = active_model_ids
        entries.each do |entry|
          label_id = entry[:label].to_s.split("/").last
          entry[:active] = active.include?(entry[:id].to_s) || active.include?(label_id)
        end

        entries
      end

      # The provider's own model catalog, as plain hashes.
      def provider_catalog_entries
        models = agent.provider_models
        models = [] unless models.is_a?(Array)
        models.filter_map do |model|
          next unless model.is_a?(Hash)

          id = (model["id"] || model["name"]).to_s.strip
          next if id.empty?

          { "id" => id, "name" => (model["name"] || id).to_s.strip }
        end
      rescue StandardError => e
        say(I18n.t("tui.model.catalog_failed", message: e.message), :warn)
        []
      end

      # The models configured in config.yml.
      def config_model_entries
        entries = []
        models = agent.config.models
        entries.concat(models.select { |model| model.is_a?(Hash) && model["name"] }) if models.is_a?(Array)

        # Fall back to (and merge with) whatever the provider's /models endpoint
        # reports, so a config without a `models:` block still has a picker.
        begin
          entries.concat(agent.provider_model_entries)
        rescue StandardError
          nil
        end

        entries.uniq { |model| model["name"].to_s }
      rescue StandardError
        []
      end

      # Every id the active model can be known by: the provider model id, the
      # config entry name and the model id of that entry.
      def active_model_ids
        ids = []
        name = agent.active_model_name.to_s
        ids << name
        ids << name.split("/").last

        entry = begin
          agent.config.model_entry_by_name(name)
        rescue StandardError
          nil
        end
        if entry.is_a?(Hash)
          model = entry["model"].to_s
          ids << model
          ids << model.split("/").last
        end

        override = begin
          agent.session.model_override.to_s
        rescue StandardError
          ""
        end
        ids << override

        ids.reject(&:empty?).uniq
      end

      def handle_use_model(model_name)
        if model_name.nil?
          say(I18n.t("tui.model.usage"), :warn)
          agent.config.models.each { |m| say_text("  - #{m["name"]}") }
          return
        end

        result = agent.use_model(model_name)
        if result
          # A config entry is known by its name, a provider model by its id.
          entry = agent.config.model_entry_by_name(model_name)
          label = entry.is_a?(Hash) && entry["model"] ? entry["model"].to_s : ""
          label = "" if label == result.to_s
          if label.empty?
            say(I18n.t("tui.model.switched", model: result), :ok)
          else
            say(I18n.t("tui.model.switched_label", model: result, label: label), :ok)
          end
          say_text(I18n.t("tui.model.provider", provider: agent.provider.name))
          say_text(I18n.t("tui.model.session_only"))
          refresh_status
          refresh_usage
        else
          say(I18n.t("tui.model.not_found", name: model_name), :err)
          agent.config.models.each { |m| say_text("  - #{m["name"]}") }
        end
      end

      def handle_use_skill(skill_name)
        skills = agent.skill_registry
        if skill_name.nil?
          say(I18n.t("tui.skill.usage"), :warn)
          say_text(I18n.t("tui.skill.available", skills: available_skills_text))
          return
        end

        skill = skills.get(skill_name)

        # A skill this persona switched off is not loaded into the turn, and
        # saying so beats letting the model quietly answer without it.
        if skill && persona_skill_off?(skill_name)
          say(I18n.t("tui.skill.off", name: skill_name), :err)
          say_text(I18n.t("tui.skill.off_hint"))
          return
        end

        if skill&.enabled?
          agent.session.forced_skill = skill_name
          agent.session.save! if agent.session.respond_to?(:save!)
          say(I18n.t("tui.skill.forced", name: skill_name), :ok)
        else
          say(I18n.t("tui.skill.not_found", name: skill_name), :err)
          say_text(I18n.t("tui.skill.available", skills: available_skills_text))
        end
      end

      # Registry names narrowed to the ones this persona left on.
      def available_skill_names
        names = agent.skill_registry.all.keys
        persona = agent.persona
        persona ? persona.enabled_skills(names) : names
      end

      def available_skills_text
        names = available_skill_names
        names.empty? ? I18n.t("tui.skill.empty") : names.join(", ")
      end

      def persona_skill_off?(name)
        persona = agent.persona
        !persona.nil? && !persona.skill_enabled?(name)
      end
    end
  end
end
