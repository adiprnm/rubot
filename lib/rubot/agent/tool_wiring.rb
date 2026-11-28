# frozen_string_literal: true

module Rubot
  class Agent
    # Stamping this turn's identity on the tool registry, and the tool calls the
    # model is shown.
    #
    # The registry is built once and shared by every session in the Ractor, so
    # the persona, the archive port and the delegate handle have to be written
    # onto it at the start of each turn; this module is that write, plus the
    # definitions the provider is sent and the parsing of what comes back.
    #
    # Moved as it was, comments included. The order of the injections is not
    # cosmetic: #inject_tool_context ends by stamping the persona, and a turn
    # that skipped that ordering answered with the previous session's slug.
    module ToolWiring
      private

      # Set the workspace on the cron tool so jobs persist to disk
      def configure_cron_tool
        cron_tool = @tools.get("cron")
        return unless cron_tool && cron_tool.respond_to?(:workspace=)
        cron_tool.workspace = @config.workspace
        # The install's own jobs live next to config.yml (~/.rubot/cron), not
        # inside the workspace the agent works in.
        cron_tool.store_root = @config.catalog_dir if cron_tool.respond_to?(:store_root=)
      end

      # Every tool instance this agent could reach. The registry is shared, so
      # the workspace, guard and persona are written onto each instance at the
      # start of a turn; there is one list, not one per capability.
      def all_tool_instances
        @tools.all
      end

      # Whether this agent is a delegated run. There is more than one spawn path
      # and only the synchronous one sets @subagent: a background run is built by
      # SessionActor from a persona alone, and a built-in role is marked internal.
      # The `~sub-` marker in the session id is what the channels already use to
      # keep these conversations out of the sidebar.
      #
      # Everything that narrows a sub agent's tools hangs off this, so a path
      # that forgets a flag cannot quietly get the full set. It did: before this
      # existed, delegated runs in the web channel were offered delegate, cron
      # and shell, because the narrowing was written inside `if @subagent`.
      def subagent_role?
        return true if @subagent
        return true if @persona&.internal

        @session.id.to_s.include?("~sub-")
      end

      # Whether this agent may only look. Derived from the tools it is offered,
      # never from a flag: a role that must not write is a role whose list holds
      # no writing tool, so the list is the whole answer. Every tool answers
      # `writes?`, and the default there is yes.
      def read_only_role?
        definitions = tool_definitions
        return false if definitions.nil? || definitions.empty?

        definitions.none?(&:writes?)
      end

      # Inject the safety guard into all tools that support it.
      # Called after @tools is assigned, ensuring the guard is applied
      # regardless of whether tools came from the Agent's constructor
      # or were passed in externally (e.g. from bin/rubot or REPL).
      def inject_safety_guard
        return unless @tools.respond_to?(:all)
        all_tool_instances.each do |tool|
          next unless tool.respond_to?(:safety_guard=)
          tool.safety_guard = @safety_guard
        end
      end

      # Tell tools where relative paths belong. The web channel roots the config
      # at the persona's directory and the TUI at the configured workspace, so
      # this is the one place that knows the right answer for both.
      def inject_tool_workspace
        return unless @tools.respond_to?(:all)
        all_tool_instances.each do |tool|
          tool.workspace = @config.workspace if tool.respond_to?(:workspace=)
        end
      end

      # Give tools the context they need to reach the archive and to scope what
      # they find there. A session actor runs on a non-main Ractor, where SQLite
      # cannot be opened; the Instagram tool uses the port to reach StoreService
      # on the main Ractor, and the persona slug to see only its own accounts.
      #
      # The registry is shared by every session actor, so the persona cannot be
      # stamped once at boot: two personas answering at the same time would keep
      # overwriting each other's slug. It is set at the start of every turn from
      # this agent's own persona instead (see #inject_tool_persona).
      def inject_tool_context
        return unless @tools.respond_to?(:all)
        port = @archive&.instance_variable_get(:@port)
        all_tool_instances.each do |tool|
          tool.store_port = port if port && tool.respond_to?(:store_port=)
        end
        inject_tool_persona
      end

      def inject_tool_persona
        return unless @tools.respond_to?(:all)

        slug = @persona&.slug.to_s
        all_tool_instances.each do |tool|
          tool.persona = slug if tool.respond_to?(:persona=)
        end
      end

      # The delegate tool needs a handle back to this agent to do the spawning.
      # Set at the start of every turn, like the persona stamp, because the tool
      # registry is shared between agents in the same Ractor.
      #
      # The loop tool needs the same handle for the same reason: in actor mode
      # the channel holds a proxy and cannot stamp a runner on it, so the tool
      # asks the agent, and the agent hands the request to the channel.
      def inject_tool_delegate
        return unless @tools.respond_to?(:all)

        %w[delegate subagent_results loop].each do |name|
          tool = @tools.get(name)
          tool.agent = self if tool && tool.respond_to?(:agent=)
        end
      end

      # Fire any due cron jobs and return their results.
      def fire_due_cron_jobs
        return [] if @cron_ractor
        cron_tool = @tools.get("cron")
        return [] unless cron_tool && cron_tool.respond_to?(:scheduler)
        scheduler = cron_tool.scheduler
        scheduler.fire_due_jobs
      rescue StandardError => e
        warn "[cron] Error firing due jobs: #{e.class}: #{e.message}"
        []
      end

      # The names a request may call, which is what a prompt sentence can safely
      # name: `tools_enabled` can switch the whole set off, and a config can trim
      # it further.
      def tool_names
        (tool_definitions || []).map(&:name)
      end

      def tool_definitions
        return nil unless @config.tools_enabled
        enabled_list = @config.enabled_tools

        tools = if enabled_list.empty?
          # A tools key that was written and left empty names no tool. Granting
          # everything there is the opposite of what naming tools is for, so it
          # is an error rather than a silent default.
          if @config.tools_declared?
            raise ArgumentError, "tools names no tool; list the tools this agent may use"
          end

          @tools.all
        else
          unknown = enabled_list - @tools.names
          raise ArgumentError, "tools names unknown tool(s): #{unknown.join(", ")}" unless unknown.empty?

          @tools.all.select { |t| enabled_list.include?(t.name) }
        end

        # Always include memory tool if memory is enabled, regardless of config
        if @memory.enabled?
          memory_tool = @tools.get("memory")
          tools << memory_tool if memory_tool && !tools.include?(memory_tool)
        end

        # Reading what a background run came back with is part of delegating, not
        # a feature of its own: a config that lists its tools by hand and enables
        # `delegate` would otherwise collect answers with no way to read them. The
        # sub agent filter below still takes it away from the sub agents
        # themselves.
        if tools.any? { |tool| tool.name == "delegate" }
          results_tool = @tools.get("subagent_results")
          tools += [ results_tool ] if results_tool && !tools.include?(results_tool)
        end

        if subagent_role?
          tools = tools.reject { |t| SUBAGENT_FORBIDDEN_TOOLS.include?(t.name) }
          if @persona&.internal
            # A role that names no tools is an error, not "everything": the
            # allowed list is the whole declaration of what the role may do.
            allowed = SubagentRegistry.allowed_tools(@persona.slug)
            tools = tools.select { |t| allowed.include?(t.name) }
          end
        end
        tools
      end

      # A call that will not run (bad arguments, a cancelled turn, a refused
      # guard question) but still owes the transcript one result per tool call.
      def skipped_call(id, name, result)
        { name: name, arguments: {}, id: id, snapshot: nil, result: result }
      end

      # Returns [name, arguments, parsed_ok]. `parsed_ok` is false when the
      # arguments were not valid JSON — which is what a tool call cut off at the
      # output limit looks like — so the caller can refuse to run it on a
      # half-read argument instead of silently executing with an empty hash.
      # The tool a call will actually run as, so the confirmation prompt, the
      # diff snapshot and the execution all see the same instance.
      def tool_instance(name)
        @tools.get(name)
      end

      # Before-content of a file a file_write edit/write/append/delete is about
      # to touch. nil for reads and every other tool: the write tool is the only
      # one that changes a file, so it is the only one that has a diff to draw.
      def file_ui_snapshot(tool_name, arguments)
        return nil unless tool_name == "file_write" && arguments.is_a?(Hash)
        return nil unless %w[write append edit delete].include?(arguments["operation"].to_s)

        path = arguments["path"].to_s
        return nil if path.empty?

        expanded = File.expand_path(path)
        before = File.exist?(expanded) ? File.read(expanded, encoding: "UTF-8") : nil
        { path: path, expanded: expanded, before: before }
      rescue StandardError
        nil
      end

      # After-content for the TUI diff, or nil when the tool did not write.
      # A delete leaves no file behind: its after-content is nil, so every line
      # the file had replays as a removal instead of disappearing from view.
      def file_ui_diff(snapshot, result)
        return nil unless snapshot
        return nil unless result.to_s.match?(/\A(?:Written|Appended|Edited|Deleted) /)

        after = File.exist?(snapshot[:expanded]) ? File.read(snapshot[:expanded], encoding: "UTF-8") : nil
        before = snapshot[:before]
        return nil if before == after
        return nil if before.to_s.length + after.to_s.length > MAX_UI_DIFF_CHARS

        { "path" => snapshot[:path], "before" => before, "after" => after }
      rescue StandardError
        nil
      end

      def parse_tool_call(tc)
        if tc.is_a?(Hash)
          fn = tc["function"]
          name = fn["name"]
          args_str = fn["arguments"]
        else
          fn = tc.function
          name = fn.name
          args_str = fn.arguments
        end

        arguments = args_str.is_a?(String) ? JSON.parse(args_str) : args_str
        return [ name, {}, false ] unless arguments.is_a?(Hash)

        [ name, arguments, true ]
      rescue JSON::ParserError, TypeError
        [ name, {}, false ]
      end

      # The set of tools this turn offers the model: what the provider is sent,
      # what `offered_tool?` checks a call against, and what a test reads to say
      # which tools a role may call. That makes it a seam rather than an
      # implementation detail, so it is named here instead of being reached for
      # with `send`.
      public :tool_definitions
    end
  end
end
