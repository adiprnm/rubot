# frozen_string_literal: true

require "json"
require_relative "config"
require_relative "model_info"
require_relative "model_catalog"
require_relative "opencode_usage"
require_relative "persona"
require_relative "pricing_catalog"
require_relative "session"
require_relative "usage"
require_relative "provider"
require_relative "tools/registry"
require_relative "safety_guard"
require_relative "soul"
require_relative "memory"
require_relative "agents_file"
require_relative "tools/memory_tool"
require_relative "memory_extractor"
require_relative "tools/feedback_learner"

module Rubot
  class Agent
    # How many times one turn may ask the model to carry on after the provider
    # cut its answer off at the output budget. Two is enough for a long reply
    # split across three requests; more usually means the budget itself is set
    # too low for the model.
    MAX_CONTINUATIONS = 2

    # Sent after a truncated answer. It has to be explicit about *not*
    # restarting: a model asked to "continue" will otherwise begin again at
    # the first sentence.
    CONTINUE_PROMPT = <<~PROMPT.strip
      Your previous message was cut off mid-sentence because it reached the
      output limit. Continue exactly where it stopped, starting with the
      remaining words of the interrupted sentence. Do not repeat anything you
      already wrote, do not start over, and do not add a preamble.
    PROMPT

    # Sent when the model finished a tool round without saying anything at all,
    # which leaves the user with silence and no images or files.
    ANSWER_NOW_PROMPT = <<~PROMPT.strip
      You ran the tools above but produced no answer. Using their results,
      reply to the user now, in the user's language. If they asked for files or
      images, send them with the send_file tool before you finish.
    PROMPT

    # Sent when a reply came back with no visible text at all — on a reasoning
    # model the whole output budget can go to the hidden reasoning, leaving an
    # empty `content`. Nothing was sent to the user, so it is asked again.
    EMPTY_ANSWER_PROMPT = <<~PROMPT.strip
      Your previous reply contained no text the user could read (the output
      budget was spent before any of it was written). Answer the user's last
      message now, directly and as briefly as the question allows.
    PROMPT

    attr_reader :config, :provider, :session, :tools, :soul, :memory, :agents_file, :skill_registry, :safety_guard, :session_model, :persona, :active_preset_name

    def initialize(config:, provider: nil, session_id: "default", tools: nil, persona: nil)
      @config = config
      @persona = Persona.from(persona)
      @session = Session.new(session_id, workspace: config.workspace)
      apply_initial_preset!
      @provider = provider || build_provider(preset: @active_preset)

      # Build safety guard from config
      @safety_guard = SafetyGuard.new(
        workspace: config.workspace,
        restrict_to_workspace: config.restrict_to_workspace,
        allow_read_outside: config.allow_read_outside_workspace
      )

      @tools = tools || Tools::Registry.new
      # Always inject safety guard into tools, even when passed from outside
      inject_safety_guard

      # Warn if safety guard is disabled
      unless @safety_guard.restrict_to_workspace
        warn "[safety] WARNING: restrict_to_workspace is DISABLED — agent has full system access"
        warn "[safety] Set restrict_to_workspace: true in config.yml to enable sandboxing"
      else
        mode = @safety_guard.allow_read_outside ? "restrict-write" : "strict"
        warn "[safety] Safety guard ENABLED (mode: #{mode}, workspace: #{@safety_guard.workspace})"
      end

      @soul = Soul.new(workspace: config.workspace)
      @memory = Memory.new(workspace: config.workspace)
      @agents_file = AgentsFile.new(workspace: config.workspace)
      @skill_registry = SkillRegistry.new(workspace: config.workspace)
      config.ensure_workspace

      # Register the memory tool so the bot can manage its own memory
      @tools.register(Tools::MemoryTool.new(@memory)) if @memory.enabled?

      # Adaptive features (always on)
      @memory_extractor = MemoryExtractor.new(provider: @provider, memory: @memory)
      @feedback_learner = Tools::FeedbackLearner.new(memory: @memory)

      # Apply AGENTS.md overrides to config
      apply_agents_overrides if @agents_file.enabled?

      # Set workspace on cron tool so jobs persist to disk
      configure_cron_tool
      @cron_ractor = nil
    end

    # Attach a CronActor handle. When present, cron jobs are owned by the
    # actor and this agent no longer fires them inline.
    def cron_ractor=(ractor)
      @cron_ractor = ractor
      cron_tool = @tools.get("cron")
      cron_tool.cron_actor = ractor if cron_tool.respond_to?(:cron_actor=)
    end

    # Create a new Agent instance with a different session but sharing
    # the same config, tools, and all shared resources.
    # This enables concurrent request processing without cross-session
    # interference — each request gets an isolated session on its
    # own agent instance.
    def for_session(session_id, persona: :inherit)
      selected_persona = persona == :inherit ? @persona : persona
      # Let Agent.new handle session loading and provider building correctly.
      # Do NOT override @provider — it was already set up for this session.
      copy = Agent.new(
        config: @config,
        session_id: session_id,
        tools: @tools,
        persona: selected_persona
      )
      # Share stateless/shared resources only (skip @provider, which
      # Agent#new already built correctly for the target session)
      copy.instance_variable_set(:@safety_guard, @safety_guard)
      copy.instance_variable_set(:@soul, @soul)
      copy.instance_variable_set(:@memory, @memory)
      copy.instance_variable_set(:@agents_file, @agents_file)
      copy.instance_variable_set(:@skill_registry, @skill_registry)
      copy.instance_variable_set(:@memory_extractor, @memory_extractor)
      copy.instance_variable_set(:@feedback_learner, @feedback_learner)
      copy
    end

    # Process a user message and return the final assistant response.
    # Due cron jobs are fired first, their output prepended to the response.
    #
    # Callbacks (optional):
    #   on_tool_call:     Called before each tool executes. Yields (tool_name, arguments).
    #   on_tool_result:   Called after each tool executes. Yields (tool_name, result).
    #   on_progress:      Called after each full round. Yields (round_count, tool_count).
    #   on_confirm:       Called before dangerous actions that could cause data loss.
    #                     Yields (tool_name, arguments). Return truthy to proceed, falsy to skip.
    #   on_assistant_text: Called with the model's own words whenever it replies
    #                     with text *and* tool calls (progress narration, e.g.
    #                     "Let me check the structure first."). Channels forward
    #                     this to the user as a regular message while work continues.
    #                     Yields (text).
    def process(message, on_tool_call: nil, on_tool_result: nil, on_progress: nil, on_confirm: nil,
                on_assistant_text: nil, stream: true, &on_chunk)
      # Fire any due cron jobs and collect their results
      cron_results = fire_due_cron_jobs
      warn "[cron] fire_due_cron_jobs returned #{cron_results.size} result(s)" if Rubot.debug?

      # Add user message to session
      @session.add("user", message)
      # Queue it for extraction; the provider call happens in #flush_learning,
      # after the channel has delivered the answer.
      @session.push_memory_backlog(message) if @memory_extractor && @memory.enabled?

      response = ""
      tool_calls = nil
      reasoning_content = nil
      rounds = 0
      limit = max_rounds
      limit_hit = false

      # The turn's answer, assembled across continuations. `response` only ever
      # holds the newest fragment; this holds all of them.
      answer = +""
      tool_rounds = 0
      continuations = 0
      reasked = false
      truncated = false
      finish_reason = nil

      loop do
        if rounds >= limit
          limit_hit = true
          break
        end

        # Adaptive: compact the transcript when it crosses the configured
        # share of the model's context window.
        run_auto_compaction

        messages = build_messages
        log_debug("Sending #{messages.size} messages to provider")

        result = if block_given? && stream
          @provider.chat_stream(messages, tools: tool_definitions) do |chunk, tool_data|
            response += chunk if chunk
            yield chunk if chunk && block_given?
          end
        else
          @provider.chat(messages, tools: tool_definitions)
        end

        record_usage(result)

        # Parse result — both streaming and non-streaming now return Hash
        if result.is_a?(Hash)
          response = result["content"] || ""
          tool_calls = result["tool_calls"]
          reasoning_content = result["reasoning_content"]
          finish_reason = result["finish_reason"]
          truncated = result["truncated"] == true
          # Some gateways close the stream without a terminator. The text is a
          # prefix of the answer even if they never said why.
          truncated ||= result["stream_incomplete"] == true && !response.to_s.empty?
        elsif result.is_a?(Array)
          # Legacy streaming format: [content, tool_calls]
          response, tool_calls = result
          reasoning_content = nil
          finish_reason = nil
          truncated = false
        else
          response = result.to_s
          tool_calls = nil
          reasoning_content = nil
          finish_reason = nil
          truncated = false
        end

        if truncated
          warn "[agent] answer truncated (finish_reason=#{finish_reason.inspect}); " \
               "#{continuations}/#{MAX_CONTINUATIONS} continuations used"
        end

        # Handle tool calls
        if tool_calls && !tool_calls.empty?
          log_debug("Got #{tool_calls.size} tool call(s)")

          # Add assistant message with tool calls to session
          @session.add("assistant", response, tool_calls: tool_calls, reasoning_content: reasoning_content)

          # Forward the model's narration before it runs the tools. This is the
          # assistant text that accompanies the tool calls ("Let me check the
          # structure first."); without this callback it would be swallowed by
          # the `response = ""` reset at the end of the round.
          narration = response.to_s.strip
          on_assistant_text&.call(narration) unless narration.empty?

          # Execute each tool call
          tool_calls.each do |tc|
            tool_name, arguments, arguments_ok = parse_tool_call(tc)
            log_debug("Executing tool: #{tool_name}")

            # Use the tool call ID for tracking
            tool_call_id = tc.is_a?(Hash) ? (tc["id"] || tool_name) : tool_name

            # A truncated answer can end in the middle of the arguments. Running
            # the tool with the snippet that survived would act on a half-read
            # path or command, so the model is told to re-issue it instead.
            if truncated && !arguments_ok
              tool_error = "ERROR: this tool call was cut off before its arguments " \
                           "finished (the answer hit the output limit). Re-issue it " \
                           "with complete arguments."
              on_tool_result&.call(tool_name, tool_error)
              @session.add("tool", tool_error, tool_call_id: tool_call_id)
              next
            end

            # Check for dangerous action that could cause data loss
            tool = @tools.get(tool_name)
            if tool && tool.respond_to?(:dangerous_action?) && tool.dangerous_action?(arguments)
              log_debug("Dangerous action detected: #{tool_name} with args: #{arguments.inspect}")
              if on_confirm && !on_confirm.call(tool_name, arguments)
                log_debug("Action cancelled by user: #{tool_name}")
                @session.add("tool", "Action cancelled by user.", tool_call_id: tool_call_id)
                next
              end
            end

            # Fire pre-execution callback
            on_tool_call&.call(tool_name, arguments)

            begin
              tool_result = @tools.execute(tool_name, arguments)
            rescue StandardError => e
              tool_result = "ERROR: #{e.class}: #{e.message}"
            end

            # Tool output can be binary (e.g. reading a PNG); keep the transcript
            # and the chat message valid UTF-8.
            tool_result = Session.normalize_utf8(tool_result.to_s)

            # Fire post-execution callback
            on_tool_result&.call(tool_name, tool_result)

            log_debug("Tool result: #{tool_result[0..200]}")

            # Add tool result to session
            @session.add("tool", tool_result, tool_call_id: tool_call_id)
          end

          # Continue the loop to get the next response
          tool_count = tool_calls.size
          response = ""
          tool_calls = nil
          rounds += 1
          tool_rounds += 1

          # Fire progress callback after each round. The tool count is captured
          # before `tool_calls` is cleared so consumers get the real number.
          on_progress&.call(rounds, tool_count)
        elsif response.to_s.strip.empty? && !reasked
          # Nothing the user can read came back. With tools in play that means
          # the model stopped without reporting; with none it means the output
          # budget went to hidden reasoning. Either way, ask once for the
          # answer instead of substituting a summary of tool output.
          reasked = true
          warn "[agent] empty answer after #{rounds} round(s); asking again"
          @session.add("user", rounds.positive? ? ANSWER_NOW_PROMPT : EMPTY_ANSWER_PROMPT)
          rounds += 1
        elsif truncated && !response.to_s.strip.empty? && continuations < MAX_CONTINUATIONS
          # The answer is a fragment. Keep it, ask for the rest, and rejoin.
          answer << response
          @session.add("assistant", response, reasoning_content: reasoning_content)
          @session.add("user", CONTINUE_PROMPT)
          continuations += 1
          rounds += 1
          finish_reason = nil
        else
          # No tool calls, we're done
          answer << response
          break
        end
      end

      # Add final assistant response to session (only if not already added via tool-call branch)
      @session.add("assistant", response, reasoning_content: reasoning_content) unless response.to_s.empty?

      # Ran out of continuations: say so rather than ending mid-sentence with
      # no explanation.
      if truncated && !answer.to_s.strip.empty?
        answer << "\n\n[the model's answer was cut off at the output limit — " \
                  "reply \"continue\" to get the rest]"
      end

      # Prepend cron results to the user's response
      # Skip inline processing if a callback is registered (Telegram handles it)
      parts = []
      cron_tool = @tools.get("cron")
      has_callback = cron_tool && cron_tool.respond_to?(:has_fire_callback?) && cron_tool.has_fire_callback?

      unless has_callback
        cron_results.each do |cr|
          warn "[cron] Processing job #{cr[:job_id]} mode=#{cr[:mode]}" if Rubot.debug?
          case cr[:mode]
          when "agent_turn"
            cron_response = process_cron(cr[:result][:agent_message])
            warn "[cron] agent_turn response: #{(cron_response || '(nil)')[0..100]}" if Rubot.debug?
            parts << cron_response if cron_response && !cron_response.empty?
          when "deliver"
            warn "[cron] deliver message: #{(cr[:result][:deliver_message] || '(nil)')[0..100]}" if Rubot.debug?
            parts << cr[:result][:deliver_message]
          when "command"
            output = cr[:result][:output] || "(no output)"
            warn "[cron] command output: #{output[0..100]}" if Rubot.debug?
            parts << "⏰ Cron job fired: #{cr[:result][:output]}"
          end
        end
      end
      parts << answer if answer && !answer.empty?

      combined = parts.join("\n\n---\n\n")

      # Guard: if the LLM produced only tool calls with no text content
      # (e.g. read_file → grep → etc.), return the cron/tool summary or
      # a fallback so the user never gets a silent drop.
      if combined.empty?
        fallback = build_fallback_response(rounds, tool_rounds: tool_rounds)
        combined = fallback if fallback && !fallback.empty?
      end

      # Say so when the run was cut short, instead of stopping silently.
      if limit_hit
        notice = "⚠️ Reached the round limit (#{limit}) before finishing. " \
                 "Reply \"continue\" to resume, or raise `max_rounds` in config.yml."
        combined = combined.empty? ? notice : "#{combined}\n\n#{notice}"
      end

      warn "[cron] Combined response (#{parts.size} parts): #{combined[0..200]}" if Rubot.debug?
      combined
    end

    def clear_session
      @session.clear!
      # /new clears history and manual overrides. The topic's persona (and the
      # configured default preset) still apply to the new session.
      apply_initial_preset!
    end

    # Switch the current session to a named model preset. The choice is saved
    # on the session and survives actor/process restarts. A full preset hash
    # may be supplied when the caller's config snapshot is newer than ours.
    def use_model_preset(name, preset: nil)
      source = preset || @config.model_preset(name)
      return nil unless source.is_a?(Hash)

      apply_preset_source(source, name: name, session_name: name)
    end

    def active_model_preset
      return nil unless @active_preset

      @config.public_model_preset(@active_preset)
    end

    def model_presets
      @config.model_preset_names.filter_map do |name|
        preset = @config.model_preset(name)
        next unless preset

        @config.public_model_preset(preset)
      end
    end

    # Switch to a different model for the current session (legacy entry-based
    # API). Prefer #use_model_preset.
    def use_model(model_name)
      model_name = model_name.to_s.strip
      return nil if model_name.empty?

      entry = @config.model_entry_by_name(model_name)
      dynamic = entry.nil? && provider_model_id?(model_name)
      return nil if entry.nil? && !dynamic

      settings = @config.provider_settings(model_name)
      @active_preset = legacy_model_preset(model_name)
      @session_model = settings.model
      @session.model_override = model_name
      @session.model_preset = nil
      @active_preset_name = "default"
      @session.save!
      @provider = Provider.build(settings)
      @session_model
    end

    # Returns the active model name (session override or config default)
    def active_model_name
      @session_model || @config.name
    end

    # Public, plain-data representation of the persona (safe to cross a
    # Ractor boundary).
    def persona_info
      @persona&.to_h
    end

    # Apply a persona to this agent. Accepts a Persona, a Hash, or nil to
    # remove the persona. Optionally accepts preset:/model:/prompt: keywords.
    # Returns the new persona as a Hash (or nil).
    def apply_persona(persona = nil, preset: nil, model: nil, prompt: nil)
      if persona.nil? && (!preset.nil? || !model.nil? || !prompt.nil?)
        persona = Persona.new(preset: preset, model: model, system_prompt: prompt)
      end

      persona = Persona.from(persona)

      if persona.nil?
        @persona = nil
        @session.model_override = nil
        @session.model_preset = nil
        apply_initial_preset!
        @session.save!
        return nil
      end

      @persona = persona
      @session.model_override = nil

      if persona.preset
        source = @config.model_preset(persona.preset)
        if source
          apply_preset_source(source, name: persona.preset, session_name: persona.preset)
        else
          @session.model_preset = nil
          apply_initial_preset!
        end
      elsif persona.model
        # Backwards compatibility for personas saved with a raw model.
        @session.model_preset = nil
        model_name = persona_model_name
        if model_name
          @active_preset = legacy_model_preset(model_name)
          @active_preset_name = "default"
          @session_model = @active_preset["model"]
          @provider = build_provider(model_name)
        else
          apply_initial_preset!
        end
      else
        @session.model_preset = nil
        apply_initial_preset!
      end

      @session.save!
      persona_info
    end

    alias set_persona apply_persona

    # Switch to a different session (e.g. per-topic in Telegram).
    # Applies the saved preset for that session, falling back to the topic's
    # persona or the configured default preset.
    def switch_session(session_id)
      return @session if @session.id == session_id
      @session = Session.new(session_id, workspace: @config.workspace)
      apply_initial_preset!
      @session
    end

    def startup_info
      model = active_model_name
      info = {
        provider: @provider.name,
        model: model,
        tools: @tools.count,
        messages: @session.message_count
      }
      info[:model_override] = true if model != @config.name
      info[:model_preset] = @active_preset_name if @active_preset_name && @active_preset_name != "default"
      info[:soul] = "yes" if @soul.enabled?
      info[:memory] = "yes" if @memory.enabled?
      info[:agents] = "yes" if @agents_file.enabled?
      info[:persona] = (@persona.name || "yes") if @persona
      info[:safety] = @safety_guard.restrict_to_workspace ? "restricted" : "permissive"
      info[:skills] = @skill_registry.count if @skill_registry.any?
      info[:adaptive] = "memory+batched-extraction+summary+feedback"
      info
    end

    # Force a compaction of the current session transcript, regardless of the
    # automatic threshold. Used by /compact. Returns plain data so it can
    # cross a Ractor boundary, or nil when there is nothing to compact.
    def compact_session
      @session.compact!(
        provider: @provider,
        keep_recent: @config.compact_keep_recent_messages,
        system_prompt: build_system_prompt
      )
    end

    # Approximate size of the next request: transcript + system prompt.
    def estimated_context_tokens
      @session.estimated_tokens(extra_chars: build_system_prompt.bytesize)
    end

    # Context window of the active model, or nil when it cannot be resolved.
    def context_window_tokens
      preset = @active_preset || {}
      entry = @config.active_model_entry || {}
      model_id = preset["model"] || @session_model || @config.model
      provider_name = preset["provider"] || @provider.name
      resolve_context_window(model_id, provider_name, preset, entry)
    end

    # Token accounting and cost estimate for the current session.
    # Returns plain data (symbol keys, numbers, strings) so it can cross a
    # Ractor boundary from a SessionActor.
    def usage_report
      preset = @active_preset || {}
      entry = @config.active_model_entry || {}
      model_id = preset["model"] || @session_model || @config.model
      provider_name = preset["provider"] || @provider.name

      window = resolve_context_window(model_id, provider_name, preset, entry)
      rates, price_source = resolve_rates(model_id, provider_name, preset, entry)

      usage = @session.usage
      last = @session.last_usage
      # After a completed turn the transcript has grown by the assistant reply,
      # so the next request's prompt is roughly prompt + completion tokens.
      context_used = last.prompt_tokens + last.completion_tokens

      {
        model: active_model_name,
        model_id: model_id,
        provider: provider_name,
        context_used: context_used,
        context_window: window,
        context_percent: window.to_i.positive? ? context_used.to_f / window * 100 : nil,
        messages: @session.message_count,
        requests: usage.requests,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        cached_tokens: usage.cached_tokens,
        cache_creation_tokens: usage.cache_creation_tokens,
        cache_hit_rate: usage.cache_hit_rate,
        total_tokens: usage.total_tokens,
        cost: Usage.cost(usage, rates),
        price_source: price_source
      }
    end

    # OpenCode Go subscription allowance for the active provider. Returns plain
    # data (see OpencodeUsage) so it can cross a Ractor boundary.
    def opencode_usage
      settings = if @active_preset
        @config.provider_settings_for_preset(@active_preset)
      else
        @config.provider_settings(@session_model)
      end
      OpencodeUsage.fetch(api_base: settings.api_base, api_key: settings.api_key)
    end

    # Tell the model to narrate its progress between tool calls. Channels
    # surface that text as chat messages, so the user can follow along instead
    # of staring at a technical "running tool" status.
    # One language for everything the bot writes. Kept here (not in the
    # configurable prompt) so a per-topic persona cannot drop it.
    SCRIPTING_RULE = <<~PROMPT.strip.freeze
      # Scripting Language

      Write every script, helper, and one-off snippet in Ruby. Use
      `ruby -e '...'` for a single expression, or write a `.rb` file and run
      `ruby path/to/script.rb` for anything longer.

      Do not write new Python to get a task done, and do not install Python
      packages. Node is only for the existing JS pipelines in the mounted
      skills, not for new helper scripts.

      Python that already exists in a repository or skill (`tools/*.py`,
      `build.sh` wrappers) is the exception: run it as-is, do not port it.
    PROMPT

    NARRATION_RULE = <<~PROMPT.strip.freeze
      # Progress Narration

      Before every tool call, write one short sentence in the same language as the
      user's message describing what you are about to do and why, for example
      "Let me look at the current structure first." or "Now I'll generate the image."
      Speak in terms of the task, not the tool: never mention tool names, function
      names, JSON arguments, or raw commands in these sentences. The user sees the
      sentence as a chat message while you work.
    PROMPT

    # Build the full system prompt from all sources
    def build_system_prompt
      @skill_registry.reload!
      parts = []

      # 1. AGENTS.md rules (behavior guidelines)
      if @agents_file.enabled? && !@agents_file.rules.empty?
        parts << "# Agent Rules\n\n#{@agents_file.rules}"
      end

      # 1b. Scripting language (Ruby for anything the bot writes itself)
      parts << SCRIPTING_RULE

      # 1c. Progress narration (channels show this to the user as messages)
      parts << NARRATION_RULE

      # 2. SOUL.md (personality and identity)
      if @soul.enabled?
        parts << "# Soul\n\n#{@soul}"
      end

      # 2b. Persona (per Telegram forum topic)
      persona_prompt = @persona&.system_prompt.to_s.strip
      unless persona_prompt.empty?
        parts << "# Persona\n\n#{persona_prompt}"
      end

      # 3. MEMORY.md (persistent context)
      if @memory.enabled?
        parts << "# Memory\n\n#{@memory}"
      end

      # 3b. Learned Corrections already live in MEMORY.md above, so they are
      # not injected a second time here — that duplicated ~200 tokens per
      # request for no extra information.

      # 3c. Conversation Summary (from session summarization)
      if @session&.summary_text
        parts << "# Previous Conversation Summary\n\n#{@session.summary_text}"
      end

      # 3d. Forced skill — injected directly to skip LLM tool-call overhead
      forced = resolve_forced_skill
      if forced
        parts << "# Active Skill: #{forced[:name]}\n\nYou MUST follow the instructions below for this response:\n\n#{forced[:content]}"
      end

      # 4. Skills (specialized instruction sets)
      skill_prompt = @skill_registry.to_system_prompt
      parts << skill_prompt unless skill_prompt.empty?

      # 4b. Current model identity (so the bot knows which model it's using)
      model_name = active_model_name
      model_entry = @config.model_entry_by_name(model_name) || @config.active_model_entry
      model_provider = model_entry["model"] || @config.model
      parts << "# Current Model\n\nYou are currently running as model: **#{model_name}** (#{model_provider}).\nWhen asked about which model you are, respond with: #{model_name}."

      # 5. Default/config system prompt. A persona prompt replaces it.
      config_prompt = persona_prompt.empty? ? @config.system_prompt : ""
      parts << config_prompt unless config_prompt.empty?

      parts.join("\n\n---\n\n")
    end

    # Learn from the turn that just finished. Channels call this *after* they
    # have delivered the answer, so extraction never delays a reply.
    #
    # A failure here must never cost the user their answer, so everything is
    # rescued and reported through the debug log only.
    def flush_learning
      run_feedback_learning
      run_memory_extraction
    rescue StandardError => e
      warn "[adaptive] learning failed: #{e.class}: #{e.message}"
    end

    private

    # Resolution order for the preset a session starts with:
    #   1. preset saved on the session (/model <preset>)
    #   2. topic persona preset
    #   3. legacy persona model
    #   4. configured default/primary preset (or the implicit `default`)
    def resolve_initial_preset
      if @session.model_preset
        preset = @config.model_preset(@session.model_preset)
        return preset if preset
      end

      if @session.model_override
        name = @session.model_override.to_s
        if @config.model_entry_by_name(name) || provider_model_id?(name)
          return legacy_model_preset(name)
        end
      end

      if @persona&.preset
        preset = @config.model_preset(@persona.preset)
        return preset if preset
      end

      if @persona&.model
        model_name = persona_model_name
        if model_name
          settings = @config.provider_settings(model_name)
          return {
            "name" => "default",
            "model" => settings.model,
            "provider" => settings.provider,
            "api_key" => settings.api_key,
            "api_base" => settings.api_base,
            "max_tokens" => settings.max_tokens,
            "temperature" => settings.temperature,
            "extra_headers" => settings.extra_headers,
            "implicit" => true
          }
        end
      end

      @config.default_model_preset
    end

    def legacy_model_preset(model_name)
      settings = @config.provider_settings(model_name)
      entry = @config.model_entry_by_name(model_name) || @config.active_model_entry || {}
      {
        "name" => "default",
        "model" => settings.model,
        "provider" => settings.provider,
        "api_key" => settings.api_key,
        "api_base" => settings.api_base,
        "max_tokens" => settings.max_tokens,
        "temperature" => settings.temperature,
        "context_window_tokens" => entry["context_window_tokens"] || entry["contextWindowTokens"],
        "pricing" => entry["pricing"],
        "extra_headers" => settings.extra_headers,
        "implicit" => true
      }
    end

    def apply_initial_preset!
      @active_preset = resolve_initial_preset || @config.default_model_preset
      @active_preset_name = @active_preset["name"]
      @session_model = @active_preset["model"]
      @provider = build_provider(preset: @active_preset)
    end

    def apply_preset_source(source, name: nil, session_name: nil)
      settings = @config.provider_settings_for_preset(source)
      preset_name = (source["name"] || source[:name] || name || "default").to_s

      @active_preset = {
        "name" => preset_name,
        "model" => settings.model,
        "provider" => settings.provider,
        "api_key" => settings.api_key,
        "api_base" => settings.api_base,
        "max_tokens" => settings.max_tokens,
        "temperature" => settings.temperature,
        "extra_headers" => settings.extra_headers,
        "reasoning_effort" => source["reasoning_effort"] || source[:reasoning_effort],
        "context_window_tokens" => source["context_window_tokens"] || source[:context_window_tokens],
        "pricing" => source["pricing"] || source[:pricing],
        "implicit" => source["implicit"] || source[:implicit] || false
      }
      @active_preset_name = preset_name
      @session_model = settings.model
      @session.model_preset = session_name || preset_name
      @session.model_override = nil
      @session.save!
      @provider = Provider.build(settings)
      active_model_preset
    end

    def apply_agents_overrides
      ag = @agents_file

      # Override config values if set in AGENTS.md frontmatter
      if ag.name
        @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
        @config.data.dig("agents", "defaults")["name"] = ag.name
      end

      if ag.model
        @config.data["model"] = ag.model
      end

      if ag.max_tokens
        @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
        @config.data.dig("agents", "defaults")["max_tokens"] = ag.max_tokens
      end

      if ag.temperature
        @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
        @config.data.dig("agents", "defaults")["temperature"] = ag.temperature
      end

      if ag.max_rounds
        @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
        @config.data.dig("agents", "defaults")["max_rounds"] = ag.max_rounds
      end

      # Apply tool overrides from AGENTS.md
      return if ag.tools_config.empty?
      tools = @config.data["tools"] || {}
      ag.tools_config.each do |tool_name, enabled|
        tools[tool_name.to_s] = { "enabled" => enabled }
      end
      @config.data["tools"] = tools unless ag.tools_config.empty?
    end

    # Set the workspace on the cron tool so jobs persist to disk
    def configure_cron_tool
      cron_tool = @tools.get("cron")
      return unless cron_tool && cron_tool.respond_to?(:workspace=)
      cron_tool.workspace = @config.workspace
    end

    # Inject the safety guard into all tools that support it.
    # Called after @tools is assigned, ensuring the guard is applied
    # regardless of whether tools came from the Agent's constructor
    # or were passed in externally (e.g. from bin/rubot or REPL).
    def inject_safety_guard
      return unless @tools.respond_to?(:all)
      @tools.all.each do |tool|
        next unless tool.respond_to?(:safety_guard=)
        tool.safety_guard = @safety_guard
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

    def build_messages
      messages = []

      # Add system prompt (composed from all sources)
      messages << { "role" => "system", "content" => build_system_prompt }

      # Add conversation history (limited)
      history_limit = @config.history_limit
      recent_messages = @session.safe_history(limit: history_limit)

      recent_messages.each do |msg|
        formatted = { "role" => msg["role"], "content" => msg["content"] }

        # Handle tool calls for assistant messages
        if msg["role"] == "assistant" && msg["tool_calls"]
          formatted["tool_calls"] = msg["tool_calls"]
        end

        # Include reasoning_content for DeepSeek and other reasoning models
        if msg["role"] == "assistant" && msg["reasoning_content"]
          formatted["reasoning_content"] = msg["reasoning_content"]
        end

        # Handle tool_call_id for tool results
        if msg["role"] == "tool"
          formatted["tool_call_id"] = msg["tool_call_id"]
        end

        messages << formatted
      end

      messages
    end

    # Build a provider from an immutable settings snapshot. No config
    # mutation is performed, so this is safe to call from any Ractor.
    def build_provider(model_name = nil, preset: nil)
      settings = if preset
        @config.provider_settings_for_preset(preset)
      else
        @config.provider_settings(model_name)
      end
      Provider.build(settings)
    end

    # Rebuild the provider using the session-level model override.
    def rebuild_provider
      return if @session_model.nil?
      return if @config.model_entry_by_name(@session_model).nil? && !provider_model_id?(@session_model)

      @provider = build_provider(@session_model)
    end

    # A model from the provider's /models catalog rather than config.yml.
    def provider_model_id?(name)
      ModelCatalog.cached_model_ids(@config.workspace).include?(name.to_s)
    end

    # Persona model name. Config entries and provider catalog ids are valid;
    # anything else falls back to the default model.
    def persona_model_name
      name = @persona&.model
      return nil if name.nil? || name.empty?

      if @config.model_entry_by_name(name).nil? && !provider_model_id?(name)
        warn "[persona] model '#{name}' is not in config.yml or the provider catalog — using the default model"
        return nil
      end

      name
    end

    def tool_definitions
      return nil unless @config.tools_enabled
      enabled_list = @config.enabled_tools

      # If no explicit tool configuration, use all registered tools
      tools = if enabled_list.nil? || enabled_list.empty?
        @tools.all
      else
        @tools.all.select { |t| enabled_list.include?(t.name) }
      end

      # Always include memory tool if memory is enabled, regardless of config
      if @memory.enabled?
        memory_tool = @tools.get("memory")
        tools << memory_tool if memory_tool && !tools.include?(memory_tool)
      end

      tools
    end

    # Returns [name, arguments, parsed_ok]. `parsed_ok` is false when the
    # arguments were not valid JSON — which is what a tool call cut off at the
    # output limit looks like — so the caller can refuse to run it on a
    # half-read argument instead of silently executing with an empty hash.
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
      [ name, arguments, true ]
    rescue JSON::ParserError
      [ name, {}, false ]
    end

    # Persist the provider's usage for this request. Streaming providers may
    # return the usage inside the result hash; otherwise read last_usage.
    def record_usage(result)
      raw = result.is_a?(Hash) ? result["usage"] : nil
      raw ||= @provider.last_usage if @provider.respond_to?(:last_usage)
      return if raw.nil?

      @session.record_usage(raw, provider: @provider.name)
    rescue StandardError => e
      warn "[usage] Failed to record usage: #{e.class}: #{e.message}" if @config.debug?
    end

    def pricing_catalog
      @pricing_catalog ||= PricingCatalog.new(config: @config)
    end

    def resolve_context_window(model_id, provider_name, preset, entry)
      override = preset["context_window_tokens"] || entry["context_window_tokens"] ||
                 entry["contextWindowTokens"]
      value = override.to_i
      return value if value.positive?

      pricing_catalog.context_window(model_id, provider: provider_name) ||
        ModelInfo.context_window(model_id)
    end

    def resolve_rates(model_id, provider_name, preset, entry)
      configured = ModelInfo.normalize_rates(preset["pricing"] || entry["pricing"])
      return [ configured, "config" ] if configured

      if provider_name.to_s == "ollama"
        return [ { "input" => 0.0, "output" => 0.0, "cached_input" => 0.0,
                   "cache_creation_input" => 0.0 }, "free" ]
      end

      catalog_rates = pricing_catalog.rates(model_id, provider: provider_name)
      return [ catalog_rates, pricing_catalog.source ] if catalog_rates

      builtin = ModelInfo.rates(model_id, provider: provider_name)
      builtin ? [ builtin, "builtin" ] : [ nil, nil ]
    end

    def log_debug(msg)
      warn "[debug] #{msg}" if @config.debug?
    end

    # Maximum number of agent rounds per message. Comes from
    # `agents.defaults.max_rounds` (config.yml or AGENTS.md frontmatter).
    # A round is one loop trip, including re-asks and continuations, not one
    # tool call.
    def max_rounds
      @config.max_rounds
    end

    # Deprecated alias for callers that still use the old name.
    alias max_tool_iterations max_rounds

    # Build a response when the turn ends with no answer of its own — the
    # model produced only tool calls and nothing to say about them. This is a
    # last resort after the re-ask, so it stays short and honest: dumping the
    # raw tool output here used to send the user things like
    # "I completed 3 step(s) of tool calls. Results: 1. [Exit code: 0]".
    def build_fallback_response(rounds, tool_rounds: 0)
      if tool_rounds.zero?
        return "⚠️ The model returned an empty reply and nothing was sent. " \
               "Reply \"continue\" to retry."
      end

      last = last_tool_name
      summary = last ? "#{tool_rounds} tool call(s), last one #{last}" : "#{tool_rounds} tool call(s)"
      round_word = rounds == 1 ? "round" : "rounds"
      "⚠️ The model stopped after #{rounds} #{round_word} and #{summary} without " \
        "writing an answer, so there is nothing to show for this turn. " \
        "Reply \"continue\" to retry."
    end

    # Name of the most recent tool the session ran, for the fallback above.
    def last_tool_name
      history = @session.safe_history(limit: @config.history_limit)
      history.reverse_each do |msg|
        next unless msg["role"] == "assistant" && msg["tool_calls"]
        call = msg["tool_calls"].last
        return nil unless call

        return call.is_a?(Hash) ? call.dig("function", "name") : call.function.name
      end
      nil
    rescue StandardError
      nil
    end

    # Resolve the forced skill for the current session, return {name, content} or nil.
    # Clears the forced_skill flag after use so it only applies once.
    def resolve_forced_skill
      skill_name = @session&.forced_skill
      return nil if skill_name.nil? || skill_name.empty?

      # Clear the flag so it only applies to the next message
      @session.forced_skill = nil
      @session.save! if @session.respond_to?(:save!)

      skill = @skill_registry.get(skill_name)
      return nil unless skill && skill.enabled?

      { name: skill.name, content: skill.content }
    end

    # -- Public methods accessible from background threads and channels --
    public

    # Process a cron message through the LLM. Called by the cron scheduler's
    # background thread.
    def process_cron(message)
      # Build local messages from session history ONLY (up to the last assistant response)
      # Do NOT include the current user message — this is a separate conversation turn
      local_messages = build_cron_messages
      local_messages << { "role" => "user", "content" => "⏰ Scheduled task fired:\n#{message}" }

      response = ""
      tool_calls = nil
      reasoning_content = nil
      rounds = 0
      limit = max_rounds

      loop do
        break if rounds >= limit

        result = @provider.chat(local_messages, tools: tool_definitions)
        record_usage(result)

        if result.is_a?(Hash)
          response = result["content"] || ""
          tool_calls = result["tool_calls"]
          reasoning_content = result["reasoning_content"]
        elsif result.is_a?(Array)
          response, tool_calls = result
          reasoning_content = nil
        else
          response = result.to_s
          tool_calls = nil
          reasoning_content = nil
        end

        if tool_calls && !tool_calls.empty?
          assistant_msg = { "role" => "assistant", "content" => response, "tool_calls" => tool_calls }
          assistant_msg["reasoning_content"] = reasoning_content if reasoning_content
          local_messages << assistant_msg

          tool_calls.each do |tc|
            tool_name, arguments, = parse_tool_call(tc)
            begin
              tool_result = @tools.execute(tool_name, arguments)
            rescue StandardError => e
              tool_result = "ERROR: #{e.class}: #{e.message}"
            end

            # Tool output can be binary (e.g. reading a PNG); keep the transcript
            # and the chat message valid UTF-8.
            tool_result = Session.normalize_utf8(tool_result.to_s)

            tool_call_id = tc.is_a?(Hash) ? (tc["id"] || tool_name) : tool_name
            local_messages << { "role" => "tool", "content" => tool_result, "tool_call_id" => tool_call_id }
          end

          response = ""
          tool_calls = nil
          rounds += 1
        else
          break
        end
      end

      # If the LLM returned empty, use the cron message itself as the response
      response = message if response.nil? || response.strip.empty?

      @session.add("assistant", response, reasoning_content: reasoning_content) unless response.empty?
      response
    end

    # Build messages for cron processing — uses conversation history
    # but excludes the current user message being processed.
    def build_cron_messages
      messages = []
      messages << { "role" => "system", "content" => build_system_prompt }

      history_limit = @config.history_limit
      all_history = @session.safe_history(limit: history_limit)

      # If the last message is a user message (the current one being processed),
      # exclude it so cron processing has clean context
      history = all_history.dup
      history.pop if history.last && history.last["role"] == "user"

      recent = history
      recent.each do |msg|
        formatted = { "role" => msg["role"], "content" => msg["content"] }
        formatted["tool_calls"] = msg["tool_calls"] if msg["role"] == "assistant" && msg["tool_calls"]
        formatted["tool_call_id"] = msg["tool_call_id"] if msg["role"] == "tool"
        formatted["reasoning_content"] = msg["reasoning_content"] if msg["role"] == "assistant" && msg["reasoning_content"]
        messages << formatted
      end

      messages
    end

    # --- Adaptive feature helpers ---

    # Run extraction once enough user messages have piled up.
    #
    # Extraction used to be one provider request per user message, issued
    # before the answer. Batching it over `memory.extract_every` messages
    # (default 3) keeps most of the coverage for a third of the requests.
    def run_memory_extraction
      return unless @memory_extractor
      return unless @memory.enabled?

      every = @config.memory_extract_every.to_i
      return unless every.positive?
      return if @session.memory_backlog.size < every

      batch = @session.take_memory_backlog
      extracted = @memory_extractor.extract(batch)

      # Extraction is a real provider request; count it in the session totals
      # without overwriting `last_usage`, which `/context` uses for context size.
      if @memory_extractor.last_usage
        @session.record_auxiliary_usage(@memory_extractor.last_usage, provider: @provider.name)
      end

      if @config.memory_consolidate?
        result = @memory.consolidate!
        warn "[memory] consolidated: removed #{result[:removed]}" if result && Rubot.debug?
      end

      return if extracted.empty?

      if Rubot.debug?
        extracted.each do |item|
          warn "[memory_extractor] Stored [#{item[:section]}]: #{item[:fact]}"
        end
      end
    end

    # Run feedback learning — detect if user is correcting the bot (always on)
    def run_feedback_learning
      return unless @feedback_learner
      return unless @memory.enabled?

      message = last_user_message
      return if message.nil?

      # The current turn is already in the transcript, so the correction is
      # matched against the answer the user is reacting to.
      @feedback_learner.process(message, @session.conversation_history)
    end

    # The last thing the user actually wrote, ignoring the prompts rubot sends
    # itself (continuation and re-ask instructions).
    def last_user_message
      @session.messages.reverse_each do |msg|
        next unless msg["role"] == "user"

        content = msg["content"].to_s.strip
        next if content.empty?
        next if [ CONTINUE_PROMPT, ANSWER_NOW_PROMPT, EMPTY_ANSWER_PROMPT ].include?(content)

        return content
      end
      nil
    end

    # Run automatic compaction when the transcript approaches the configured
    # share of the model's context window. The estimate is recomputed from the
    # transcript each time, so a compaction immediately lowers it and the next
    # round does not compact again.
    def run_auto_compaction
      return unless @config.auto_compact?
      return if @session.message_count <= @config.compact_keep_recent_messages

      window = context_window_tokens
      return unless window.to_i.positive?

      threshold = window * (@config.compact_threshold_percent / 100.0)
      used = estimated_context_tokens
      return if used < threshold

      result = compact_session
      if result && Rubot.debug?
        warn "[compaction] auto: #{result[:summarized_messages]} messages summarized, " \
             "context #{result[:context_before]} -> #{result[:context_after]} tokens (estimated)"
      end
      result
    end
  end
end
