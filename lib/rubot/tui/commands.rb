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
        when "/help"
          blank
          say("Available commands:", :info)
          COMMANDS.each do |syntax, desc|
            say_text(format("  %-20s %s", syntax, desc))
          end
          blank
          say("Keys:", :info)
          KEYS.each do |keys, desc|
            say_text(format("  %-20s %s", keys, desc))
          end
          blank
        when "/clear"
          agent.clear_session
          @events << [ :reset_turn_totals ]
          say("Session cleared.", :ok)
          refresh_usage
        when "/new"
          # Silent restart: wipe the screen and start a fresh session.
          @command_owns_blank = true
          agent.clear_session
          @events << [ :clear_log ]
          refresh_status
        when "/stop"
          agent.cancel!
          say("Stop requested.", :ok)
        when "/compact"
          result = agent.compact_session
          if result
            say("Compaction complete.", :ok)
            say_text("Summarized: #{result[:summarized_messages]} messages")
            say_text("Kept:       #{result[:kept_messages]} messages")
            say_text("Context:    ~#{result[:context_before]} → ~#{result[:context_after]} tokens (estimated)")
          else
            say("Nothing to compact yet (conversation is short or summarization failed).", :info)
          end
          refresh_usage
        when "/repin"
          # The prompt is pinned so the cached prefix survives a memory write, so
          # a line added to MEMORY.md mid-session is invisible until the epoch
          # moves. This is the door, and the price is on the tin: one request paid
          # in full, because the prefix moves with the prompt.
          if agent.repin_system_prompt
            say("System prompt will be rebuilt on the next message.", :ok)
            say_text("Memory, skills and AGENTS.md changed since this session started are picked up.")
            say_text("Cost: the next request pays in full — the prefix moved, so the cache is gone once.")
          else
            say("The prompt is not pinned; the next message builds it from the latest files anyway.", :info)
          end
        when "/session"
          if parts[1]
            switch_session(parts[1])
            say("Session switched to: #{parts[1]}", :ok)
            refresh_status
            refresh_usage
          else
            say("Current session: #{agent.session.id}", :info)
            say_text("Model: #{agent.active_model_name}")
            say_text("Type /resume to browse saved sessions.")
          end
        when "/resume"
          handle_resume(parts[1])
        when "/search"
          handle_search(parts[1..].join(" "))
        when "/info"
          say("Agent info:", :info)
          agent.startup_info.each { |k, v| say_text("#{k}: #{v}") }
        when "/context"
          blank
          # Mid-turn the agent is busy with the answer, so the report it last
          # published is what there is to show — the same numbers the footer
          # is moving.
          report = @live_report || agent.usage_report
          say_text(Rubot::UsageReport.render(report))
          say_text("live — the request in flight is not in these totals yet") if @live_report
          blank
        when "/usage"
          blank
          say_text(Rubot::OpencodeUsageReport.render(agent.opencode_usage))
          blank
        when "/timing"
          blank
          say_text(Rubot::Timing.report)
          blank
        when "/models"
          handle_models_command(parts[1])
        when "/model"
          active = agent.active_model_name
          entry = agent.config.model_entry_by_name(active) || agent.config.active_model_entry
          say("Current model: #{active} (#{entry["model"]})", :info)
          say("Session override — cleared on /new.", :warn) if agent.session.model_override
        when "/use-model"
          handle_use_model(parts[1])
        when "/tools"
          say("Available tools:", :info)
          agent.tools.all.each do |tool|
            say_text("  - #{tool.name}: #{tool.description.lines.first.strip}")
          end
        when "/soul"
          if agent.soul.enabled?
            say("Soul (SOUL.md):", :info)
            say_text(agent.soul.read, :text)
          else
            say("No soul file (SOUL.md) found in workspace.", :warn)
          end
        when "/memory"
          if agent.memory.enabled?
            memory = agent.memory
            if memory.respond_to?(:global_path)
              say("Memory — global: #{memory.global_path}", :info)
              say("Memory — this workspace: #{memory.workspace_path}", :info)
            else
              say("Memory (MEMORY.md):", :info)
            end
            say_text(memory.read, :text)
          else
            say("Memory not available (no workspace configured).", :warn)
          end
        when "/agents"
          if agent.agents_file.enabled?
            say("Agent rules (AGENTS.md):", :info)
            say_text(agent.agents_file.raw, :text)
          else
            say("No AGENTS.md found in workspace.", :warn)
          end
        when "/delegates"
          handle_delegates_command
        when "/cron"
          cron_tool = agent.tools.get("cron")
          if cron_tool
            say_text(cron_tool.execute({ "operation" => "list" }).to_s, :text)
          else
            say("Cron tool not available.", :warn)
          end
        when "/web-restart"
          restart_web_channel
        when "/auto"
          handle_auto_command(parts[1])
        when "/stream"
          @stream = parts[1].downcase == "on" if parts[1]
          say("Streaming #{@stream ? "on" : "off"}.", :info)
        when "/use"
          handle_use_skill(parts[1])
        when "/unuse"
          if agent.session.forced_skill
            agent.session.forced_skill = nil
            agent.session.save! if agent.session.respond_to?(:save!)
            say("Forced skill cleared.", :ok)
          else
            say("No forced skill is set.", :info)
          end
        when "/quit", "/exit"
          @app ? @app.quit : exit
        else
          say("Unknown command: #{cmd}.", :err)
          say_text("Type /help for available commands.")
        end
      rescue StandardError => e
        say("#{e.class}: #{e.message}", :err)
        raise if Rubot.debug?
      ensure
        flush_command_output
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
          say("Web server restarted.", :ok)
          # The script reports one line on success: the pid and the address.
          line = output.lines.map(&:strip).reject(&:empty?).last
          say_text(line) if line
        else
          say("Web server restart failed.", :err)
          output.lines.map(&:strip).reject(&:empty?).last(3).each { |line| say_text(line) }
        end
      end

      # The personas a lead agent can hand work to. Read fresh from the store so
      # a persona created after launch shows up. Says plainly when delegation is
      # off, since listing targets that cannot be used would be misleading.
      def handle_delegates_command
        config = agent.config
        unless config.respond_to?(:delegation_enabled?) && config.delegation_enabled?
          say("Delegation is off. Set delegation.enabled: true in config.yml.", :warn)
          return
        end

        store = Rubot::PersonaStore.new(
          dir: File.dirname(config.personas_file),
          legacy_workspace: config.workspace
        )
        specialists = store.specialists
        if specialists.empty?
          say("No personas to delegate to yet.", :warn)
          return
        end

        say("Delegates (#{specialists.size}):", :info)
        specialists.each do |slug, persona|
          model = persona.model.to_s
          label = "#{persona.emoji_or} #{persona.label} (#{slug})"
          label += " · #{model}" unless model.empty?
          say_text("  - #{label}")
        end
      rescue StandardError => e
        say("Could not list delegates: #{e.class}: #{e.message}", :err)
      end

      def handle_auto_command(argument)
        word = argument.to_s.strip.downcase
        wanted = if word.empty?
          !auto_mode?
        elsif AUTO_TOGGLE.key?(word)
          AUTO_TOGGLE[word]
        end

        if wanted.nil?
          say("Usage: /auto on|off (no argument flips it).", :err)
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
          say("Auto mode on — non-destructive actions run without asking.", :warn)
          say_text("Destructive patterns (rm -rf /, mkfs, dd onto a device, …) are still refused.")
        else
          say("Auto mode off — every dangerous action asks first.", :info)
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
          say("Session '#{text}' not found.", :err)
          say_text("Type /resume to see saved sessions.")
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
          say("No saved sessions yet.", :info)
          say_text("Conversations are saved as they happen; /resume brings one back later.")
          others = other_dir_sessions
          say_text("#{others} conversation(s) from other directories · /resume all") if others.positive?
          return
        end

        current = agent.session.id
        blank
        say("Saved sessions:", :info)
        sessions.each_with_index do |session, index|
          marker = session[:id] == current ? MARK[:ok] : " "
          say_text(format("  %s %-2d %-28s %4d msgs · %-10s %s",
                          marker, index + 1, session[:id], session[:messages],
                          relative_time(session[:updated_at]), Rubot::Session.label(session)))
        end
        blank
        say_text("Resume one with /resume <number> or /resume <id>.")
        others = other_dir_sessions
        say_text("#{others} more from other directories · /resume all") if others.positive?
      end

      # /search asks the archive, not the session on screen: every message ever
      # stored, including the turns a compacted conversation no longer shows the
      # model — which is the reason the archive is kept. The store answers
      # best-first (bm25 over three weighted columns, see Store#search), and each
      # hit names the session it came from because that is what /resume takes.
      def handle_search(query)
        text = query.to_s.strip
        if text.empty?
          say("Search the archive:", :info)
          say_text("/search <kata> — every stored message, including compacted turns")
          return
        end

        store = Rubot::Session.store
        if store.nil?
          say("The archive is not open, so there is nothing to search.", :warn)
          say_text("Search reads the SQLite archive; without it, conversations are files and /resume lists them.")
          return
        end

        hits = store.search(text, limit: SEARCH_RESULTS)
        if hits.empty?
          say("Nothing matches #{text.inspect}.", :info)
          return
        end

        blank
        say("#{hits.size} hit(s) for #{text.inspect}:", :info)
        hits.each_with_index do |hit, index|
          say_text(format("  %-2d %-26s %-9s %s", index + 1, hit[:session_id], hit[:role],
                          relative_time(hit[:created_at])))
          # One line per hit: a terminal wraps, and a wrapped snippet would push
          # the next hit away from its own id.
          say_text("     #{snippet_line(hit[:snippet])}")
        end
        blank
        say_text("Resume one with /resume <id>.")
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
          say("No models available.", :warn)
          say_text("The provider returned no model catalog, and config.yml has no models.")
          return
        end

        filter = query.to_s.strip
        shown = entries.select { |entry| Rubot::TUI::ModelList.matches?(entry, filter) }
        if shown.empty?
          say("No model matches '#{filter}'.", :warn)
          return
        end

        if @tui
          @command_owns_blank = true
          @events << [ :model_list, entries, model_list_title(entries), filter ]
        else
          say("Models supported by #{provider_name}:", :info)
          shown.each do |entry|
            marker = entry[:active] ? MARK[:ok] : " "
            label = entry[:label].to_s
            label = "" if label == entry[:id].to_s
            say_text("  #{marker} #{entry[:id]}#{label.empty? ? "" : " (#{label})"}")
          end
        end
      end

      def model_list_title(entries)
        "Models supported by #{provider_name}"
      end

      def provider_name
        agent.provider.name
      rescue StandardError
        "the provider"
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
        say("Could not read the model catalog: #{e.message}", :warn)
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
          say("Usage: /use-model <model-name>", :warn)
          agent.config.models.each { |m| say_text("  - #{m["name"]}") }
          return
        end

        result = agent.use_model(model_name)
        if result
          # A config entry is known by its name, a provider model by its id.
          entry = agent.config.model_entry_by_name(model_name)
          label = entry.is_a?(Hash) && entry["model"] ? entry["model"].to_s : ""
          label = "" if label == result.to_s
          say("Switched to model: #{result}#{label.empty? ? "" : " (#{label})"}", :ok)
          say_text("Provider: #{agent.provider.name}")
          say_text("Persists for this session (cleared on /new).")
          refresh_status
          refresh_usage
        else
          say("Model '#{model_name}' not found in config.yml or the provider catalog.", :err)
          agent.config.models.each { |m| say_text("  - #{m["name"]}") }
        end
      end

      def handle_use_skill(skill_name)
        skills = agent.skill_registry
        if skill_name.nil?
          say("Usage: /use <skill-name>", :warn)
          say_text("Available skills: #{available_skills_text}")
          return
        end

        skill = skills.get(skill_name)

        # A skill this persona switched off is not loaded into the turn, and
        # saying so beats letting the model quietly answer without it.
        if skill && persona_skill_off?(skill_name)
          say("Skill '#{skill_name}' is switched off for this persona.", :err)
          say_text("Turn it back on from the persona's skills list.")
          return
        end

        if skill&.enabled?
          agent.session.forced_skill = skill_name
          agent.session.save! if agent.session.respond_to?(:save!)
          say("Skill '#{skill_name}' will be used for the next message.", :ok)
        else
          say("Skill '#{skill_name}' not found or not enabled.", :err)
          say_text("Available skills: #{available_skills_text}")
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
        names.empty? ? "(none)" : names.join(", ")
      end

      def persona_skill_off?(name)
        persona = agent.persona
        !persona.nil? && !persona.skill_enabled?(name)
      end
    end
  end
end
