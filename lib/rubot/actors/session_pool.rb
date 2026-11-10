# frozen_string_literal: true

require_relative "cron_actor"
require_relative "session_actor"
require_relative "../config"
require_relative "../persona_store"
require_relative "../session_handle"
require_relative "../store"
require_relative "../store_service"

module Rubot
  module Actors
    # Main-Ractor-side registry of session actors (one actor per session id).
    #
    # The pool is intentionally not Ractor-shareable: it is owned by the
    # main Ractor (where channels run). Use #for to obtain a SessionHandle.
    class SessionPool
      attr_reader :cron, :cron_events, :workspace, :models, :sessions_dir, :sessions_cwd
      attr_reader :store, :store_service

      def initialize(config:, delivery: nil)
        @config_data = config.snapshot
        @config_path = config.config_path
        @workspace = config.workspace
        # One central sessions directory, plus the launch directory each
        # session is tagged with (see Config#sessions_dir / #sessions_cwd).
        @sessions_dir = config.sessions_dir
        @sessions_cwd = config.sessions_cwd
        @models = Array(config.models)
        @mutex = Mutex.new
        @actors = {}
        @cron_workspaces = {}
        @cron_events = delivery
        @persona_store = build_persona_store(config)

        # The archive lives here because this runs in the main Ractor, where
        # SQLite is allowed. Actors reach it through `store_port`; readers
        # through Session.store. A failure to open it falls back to JSON.
        @store, @store_service = open_store(@sessions_dir)
        Session.store = @store

        @cron = if config.tools_enabled
          CronActor.new(
            workspace: config.workspace,
            restrict_to_workspace: config.restrict_to_workspace,
            allow_read_outside: config.allow_read_outside_workspace,
            delivery: delivery
          )
        end

        # A persona's reminders live in its own store, which the CronActor only
        # knows about once something opens it. Open them at boot, or a
        # specialist's reminders would go quiet until their topic was used
        # again — which, for a reminder, may be never.
        register_persona_cron_stores
      end

      # Open every persona directory that has a job store on disk.
      def register_persona_cron_stores
        return unless @cron

        @persona_store.specialists.each do |slug, _persona|
          dir = @persona_store.workspace_for(slug)
          next unless dir && File.exist?(File.join(dir, "cron", "jobs.json"))

          cron_for(dir)
        end
      rescue StandardError => e
        warn "[cron] could not reopen persona stores: #{e.class}: #{e.message}"
      end

      # One CronActor serves every workspace. Its scheduler keeps one job store
      # per directory (the install's own, plus one per persona as needed), so a
      # reminder written from a persona's topic is filed with that persona and
      # fires back into it, without a firing thread per directory.
      #
      # Returns the handle, or nil when the cron tool is disabled.
      def cron_for(workspace)
        return nil unless @cron

        path = workspace.to_s
        return @cron if path.empty?

        full = File.expand_path(path)
        return @cron if full == File.expand_path(@workspace)

        registered = @mutex.synchronize do
          @cron_workspaces[full] ||= begin
            @cron.call(
              operation: "register",
              arguments: { "operation" => "register", "workspace" => full }
            )
            full
          end
        end
        registered.is_a?(String) ? @cron : nil
      rescue StandardError => e
        warn "[cron] could not open the store for #{workspace}: #{e.class}: #{e.message}"
        @cron
      end

      # Close a workspace's job store.
      #
      # By default its reminders are dropped: they were written in a voice that
      # is going away. `keep: true` moves them to the install's own store
      # instead, for a caller that only wants the directory gone.
      def unregister_cron_workspace(workspace, keep: false)
        return 0 unless @cron

        full = File.expand_path(workspace.to_s)
        return 0 if full == File.expand_path(@workspace)

        @mutex.synchronize { @cron_workspaces.delete(full) }
        result = @cron.call(
          operation: "merge",
          arguments: {
            "operation" => "merge",
            "workspace" => full,
            # The Ractor boundary serialises plain values, so say "nowhere"
            # with an empty target rather than relying on nil surviving.
            "to" => keep ? @workspace.to_s : ""
          }
        )
        result.is_a?(Integer) ? result : 0
      rescue StandardError => e
        warn "[cron] could not close the store for #{workspace}: #{e.class}: #{e.message}"
        0
      end

      # Drop every reminder aimed at one chat/topic — what a topic's persona
      # reset needs: the job was written with a specialist's memory, so it must
      # not keep firing after the persona is gone.
      def remove_cron_jobs_for(chat_id:, thread_id: nil)
        return 0 unless @cron

        result = @cron.call(
          operation: "remove_by_target",
          arguments: {
            "operation" => "remove_by_target",
            "chat_id" => chat_id,
            "thread_id" => thread_id
          }
        )
        result.is_a?(Integer) ? result : 0
      rescue StandardError => e
        warn "[cron] could not clear reminders for #{chat_id}/#{thread_id}: #{e.class}: #{e.message}"
        0
      end

      # Returns a SessionHandle for the given session id, spawning the actor
      # lazily. Calls with the same id always return the same actor.
      def for(session_id)
        sid = (session_id || "default").to_s

        # Resolve the workspace and its cron store before taking the lock:
        # cron_for takes the same lock, and open the pool's mutex recursively
        # is a deadlock.
        workspace = nil
        cron = nil
        @mutex.synchronize { workspace = persona_workspace_for(sid) }
        cron = cron_for(workspace || @workspace) if @cron

        ractor = @mutex.synchronize do
          @actors[sid] ||= SessionActor.new(
            config_data: config_data_for(sid),
            config_path: @config_path,
            session_id: sid,
            cron_actor: cron,
            persona: persona_for(sid),
            store_port: @store_service&.port
          )
        end

        SessionHandle.new(ractor.ractor, sid, ractor.stop_port)
      end

      def session_ids
        @mutex.synchronize { @actors.keys.dup }
      end

      # Pick up config.yml changes (model presets, defaults, credentials) for
      # actors spawned after this call. Live actors keep their in-memory config
      # until they are switched explicitly or recreated.
      def refresh_config(config)
        @mutex.synchronize do
          @config_data = config.snapshot
          @config_path = config.config_path
          @workspace = config.workspace
          @sessions_dir = config.sessions_dir
          @sessions_cwd = config.sessions_cwd
          @models = Array(config.models)
          @persona_store = build_persona_store(config)
        end
        self
      end

      # Drop a session actor so the next #for call recreates it from the
      # current persona store and session file.
      def invalidate(session_id)
        sid = (session_id || "default").to_s
        actor = @mutex.synchronize { @actors.delete(sid) }
        actor&.shutdown
        actor
      end

      def shutdown
        actors = @mutex.synchronize do
          list = @actors.values
          @actors = {}
          list
        end

        actors.each(&:shutdown)
        @cron&.shutdown
        # After the actors: one of them may still be mid-turn and writing.
        @store_service&.stop
        Session.store = nil if Session.store.equal?(@store)
      end

      private

      # The archive and its service, or [nil, nil] when it cannot be opened.
      #
      # Falling back to the JSON files is deliberate: a database that will not
      # open (a read-only home, a corrupt file) is a bad day, but a bot that
      # refuses to start over it is a worse one.
      def open_store(sessions_dir)
        return [ nil, nil ] if sessions_dir.to_s.empty?

        path = Store.path_for(sessions_dir)
        store = Store.new(path)
        # Importing is separate from opening on purpose: three channels boot
        # against the same file, and a busy database during the import must not
        # throw away a store that opened perfectly well.
        begin
          imported = store.import_directory(sessions_dir, skip_existing: true)
          if imported[:sessions].positive?
            warn "[store] imported #{imported[:sessions]} session(s) from JSON " \
                 "(#{imported[:messages]} messages) into #{path}"
          end
        rescue StandardError => e
          warn "[store] import from #{sessions_dir} failed: #{e.class}: #{e.message}"
        end
        [ store, StoreService.new(store) ]
      rescue StandardError => e
        warn "[store] could not open #{path || "the archive"}: #{e.class}: #{e.message}; " \
             "sessions stay in JSON files"
        store&.close
        [ nil, nil ]
      end

      def build_persona_store(config)
        PersonaStore.new(
          dir: File.dirname(config.config_path),
          legacy_workspace: config.workspace,
          available_models: Array(config.models).filter_map { |model| model["name"] if model.is_a?(Hash) },
          available_presets: config.model_preset_names
        )
      end

      # Plain-data persona for a session, read fresh from disk so a topic
      # created (or reconfigured) after the pool started is picked up.
      def persona_for(session_id)
        persona = @persona_store.get_by_session(session_id)
        persona&.to_h
      rescue StandardError => e
        warn "[persona] failed to load persona for #{session_id}: #{e.class}: #{e.message}"
        nil
      end

      # A persona that owns a workspace gets a config rooted there, so its
      # SOUL.md, AGENTS.md, skills/ and memory file are its own instead of the
      # main workspace's. Sessions stay central: sessions_dir comes from the
      # config path, which this copy keeps.
      def config_data_for(session_id)
        workspace = persona_workspace_for(session_id)
        return @config_data unless workspace

        Config
          .from_data(@config_data, config_path: @config_path)
          .with_persona_workspace(workspace)
          .snapshot
      rescue StandardError => e
        warn "[persona] could not root #{session_id} at its workspace: #{e.class}: #{e.message}"
        @config_data
      end

      # Where an existing session id would be rooted, without spawning it.
      def workspace_for_session(session_id)
        persona_workspace_for(session_id.to_s)
      end

      def persona_workspace_for(session_id)
        key = PersonaStore.key_for_session(session_id)
        return nil unless key

        @persona_store.workspace_for(key)
      end
    end
  end
end
