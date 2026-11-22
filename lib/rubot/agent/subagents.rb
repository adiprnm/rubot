# frozen_string_literal: true

module Rubot
  class Agent
    # Delegation: one self-contained task, run in another persona's workspace.
    #
    # #spawn_subagent used to sit beside #process in agent.rb, next to the
    # provider loop and the usage figures it has nothing to do with. It is the
    # only part of an agent that reaches into another persona, and it reads as
    # one story: the guards, the accounting, the hand-off to a channel that can
    # run it later, the run itself, and what it leaves in the audit table.
    #
    # Moved as it was, comments included. The audit rows and the progress
    # events are what a channel draws, and their order is part of the contract.
    module Subagents
      # Run one self-contained task in another persona and return its written
      # answer. Called by the delegate tool from inside this agent's turn, so it
      # runs on the same thread in the same Ractor: no new actor, no lock, no
      # cross-Ractor message. The sub agent gets its own session and a config
      # rooted at the target persona's workspace, so its memory and files are
      # that persona's, not the caller's.
      #
      # Guards: delegation must be enabled, the slug must name a real persona,
      # the depth and per-turn count must be within config limits. A refusal is
      # returned as a string the model can read, never raised into the turn.
      def spawn_subagent(agent_slug:, task:, model: nil)
        unless @config.delegation_enabled?
          return "ERROR: delegation is disabled in config (delegation.enabled)."
        end
        if @subagent_depth >= @config.delegation_max_depth
          return "ERROR: a sub agent cannot delegate further."
        end

        slug = agent_slug.to_s.strip.downcase
        return "ERROR: no agent slug given." if slug.empty?
        return "ERROR: cannot delegate to the current agent." if slug == @persona&.slug.to_s

        persona = load_subagent_persona(slug)
        return "ERROR: unknown agent #{slug.inspect}." unless persona

        allowed = @subagent_mutex.synchronize do
          if @subagent_count < @config.delegation_max_per_turn
            @subagent_count += 1
            true
          else
            false
          end
        end
        unless allowed
          return "ERROR: delegation limit reached for this turn (#{@config.delegation_max_per_turn})."
        end

        run_id = SecureRandom.hex(6)
        audit_start(run_id, slug, task, model)
        emit_subagent(run_id, slug, :started, task)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # A channel that can run the sub agent outside this session asks for it
        # here and gets its answer back later. The parent turn ends with the run
        # still going, which is the point: the reader is not held by work they
        # delegated. The request carries plain data only — the executor builds the
        # sub agent from the slug, because an object graph cannot leave a Ractor.
        if (hand_off = @on_delegate)
          hand_off.call(
            run_id: run_id, agent: slug, task: task.to_s, model: model.to_s,
            parent_session: @session.id.to_s
          )
          return "Sub agent #{slug} started in the background (run #{run_id}). " \
                 "It keeps working after this turn ends. Call subagent_results to read what it found."
        end

        begin
          sub = build_subagent(persona, slug, run_id, model)
          answer = sub.process(
            task,
            stream: false,
            on_subagent: @on_subagent,
            on_tool_call: ->(name, args, _snapshot) {
              emit_subagent(run_id, slug, :tool, "#{name} #{summarize_subagent_args(args)}")
            },
            on_assistant_text: ->(text) { emit_subagent(run_id, slug, :thinking, text) }
          )
          audit_finish(run_id, "done", sub_session: sub.session.id)
          emit_subagent(run_id, slug, :done,
                        Formatting.duration(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started))
          answer.to_s
        rescue StandardError => e
          audit_finish(run_id, "failed", error: "#{e.class}: #{e.message}")
          emit_subagent(run_id, slug, :failed, e.message)
          "ERROR: sub agent #{slug} failed: #{e.class}: #{e.message}"
        end
      end

      # What background runs came back with, for the model to read.
      #
      # A delegated run that outlives its turn cannot answer into that turn, so it
      # writes here instead. Each answer is handed over once: the rows are marked
      # as reported by the same call that returns them, which is also why an empty
      # answer is a sentence rather than an error — "nothing new" is a normal
      # thing to ask and hear.
      def subagent_results(run_id: nil)
        return "ERROR: no archive is open, so delegated results cannot be read here." unless @archive

        rows = Array(@archive.pending_subagent_results(@session.id.to_s))
        wanted = run_id.to_s.strip
        rows = rows.select { |row| row[:run_id].to_s == wanted } unless wanted.empty?

        if rows.empty?
          return "No delegated run has finished with an answer you have not already seen."
        end

        @archive.mark_subagent_results_reported(rows.map { |row| row[:run_id] })
        rows.map { |row| "== run #{row[:run_id]} · #{row[:agent_slug]} ==\n#{row[:result]}" }.join("\n\n")
      end

      private

      # Read the persona registry fresh from disk so a persona created after the
      # pool started can still be delegated to. Only specialists (slug keys) are
      # valid targets: a Telegram topic key is a conversation, not an agent.
      def load_subagent_persona(slug)
        store = PersonaStore.from_config(
          @config,
          dir: @config.respond_to?(:personas_dir) ? File.dirname(@config.personas_file) : File.join(Dir.home, ".rubot"),
          available_presets: @config.respond_to?(:model_preset_names) ? @config.model_preset_names : []
        )
        persona = store[slug]
        return nil unless persona && !persona.reference?
        return nil unless PersonaStore.slug_for_key(slug)

        persona
      rescue StandardError => e
        warn "[delegate] could not load persona #{slug}: #{e.class}: #{e.message}"
        nil
      end

      # Build the sub agent. Its config is re-rooted at the target persona's
      # workspace (SOUL, MEMORY, files), while sessions stay in the central
      # directory. The session id carries a `~sub-` marker so channels can keep
      # these internal conversations out of the sidebar.
      def build_subagent(persona, slug, run_id, model_override)
        config = delegated_config(slug)

        sub = Agent.new(
          config: config,
          provider: resolve_subagent_provider(slug),
          session_id: "#{@session.id}~sub-#{run_id}",
          persona: SubagentSpec.persona_data(config: config, persona: persona, slug: slug, model_override: model_override),
          archive: @archive
        )
        sub.cancellation = @cancellation
        sub.cron_ractor = @cron_ractor if @cron_ractor
        sub.on_subagent = @on_subagent
        sub.instance_variable_set(:@subagent, true)
        sub.instance_variable_set(:@subagent_depth, @subagent_depth + 1)
        sub
      end

      # The parent's config, rooted at the persona's workspace when it has one.
      def delegated_config(slug)
        base_config = @config.respond_to?(:with_persona_workspace) ? @config : Config.from_data(@config.snapshot, config_path: @config.config_path)
        workspace = SubagentSpec.workspace_for(config: base_config, slug: slug)
        workspace ? base_config.with_persona_workspace(workspace) : base_config
      end

      # Write the audit rows through the archive port when one is available.
      # In-process agents (tests, REPL) have no archive, so auditing is a no-op
      # there — the feature must never depend on the database being open.
      def audit_start(run_id, slug, task, model)
        return unless @archive

        @archive.start_subagent_run(
          run_id: run_id, parent_session: @session.id, agent_slug: slug,
          task: task, model: model
        )
      rescue StandardError => e
        warn "[delegate] could not audit start: #{e.class}: #{e.message}"
      end

      def audit_finish(run_id, status, sub_session: nil, error: nil)
        return unless @archive

        @archive.finish_subagent_run(
          run_id: run_id, status: status, sub_session: sub_session, error: error
        )
      rescue StandardError => e
        warn "[delegate] could not audit finish: #{e.class}: #{e.message}"
      end

      # A provider injected for tests, or nil so the sub agent builds its own
      # from the target persona's config. A callable receives the persona slug.
      def resolve_subagent_provider(slug)
        factory = @subagent_provider
        return nil if factory.nil?

        factory.respond_to?(:call) ? factory.call(slug) : factory
      end

      # Push a progress event to the channel, if one is listening. Plain data
      # only, so it can cross a Ractor boundary through the actor's port.
      def emit_subagent(run_id, slug, phase, detail)
        @on_subagent&.call({
          run_id: run_id,
          agent: slug,
          phase: phase,
          detail: detail.to_s,
          depth: @subagent_depth
        })
      end

      def summarize_subagent_args(args)
        return "" unless args.is_a?(Hash)

        text = args.values.find { |v| v.is_a?(String) && v.length > 24 }
        text ||= args.values.first
        text.to_s.tr("\n", " ")[0, 60]
      end
    end
  end
end
