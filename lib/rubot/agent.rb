# frozen_string_literal: true

require "json"
require "digest"
require "securerandom"
require_relative "cancellation"
require_relative "config"
require_relative "model_info"
require_relative "model_catalog"
require_relative "opencode_usage"
require_relative "persona"
require_relative "persona_store"
require_relative "subagent_registry"
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
require_relative "agent/subagents"
require_relative "agent/system_prompt"
require_relative "agent/tool_execution"
require_relative "agent/turn"
require_relative "agent/turn_callbacks"
require_relative "agent/turn_loop"
require_relative "agent/usage_accounting"
require_relative "tools/feedback_learner"

module Rubot
  class Agent
    # How many times one turn may ask the model to carry on after the provider
    # cut its answer off at the output budget. Each continuation buys another
    # `max_tokens` worth of text, and only ever fires when the provider really
    # did truncate — so a generous number costs nothing on ordinary answers and
    # stops a long one from ending mid-sentence. Two was too few: a written
    # document at 16k output tokens needs three or four requests, and at two the
    # reader got a notice and a "continue" they had to type.
    MAX_CONTINUATIONS = 4

    # How often a turn in flight may publish provisional cost/context figures.
    # Five times a second keeps the footer moving without turning every
    # streamed chunk into an event the UI has to drain.
    LIVE_USAGE_INTERVAL = 0.2

    # Tool results kept verbatim in the request. Everything older is shortened:
    # a tool-heavy turn re-sends its entire stdout on every round, and the
    # model rarely needs the full log of a command it already acted on.
    # The session file still keeps the complete output; only the request is
    # trimmed, so nothing is lost for a later turn that needs to re-read it.
    TRUNCATED_TOOL_RESULT_NOTICE = "\n... [older tool output truncated; re-run the command if you still need it]"

    # Appended to an oversized argument value of an old tool call after its

    # first `tool_result_max_chars` characters. The count tells the model what

    # it is missing without ever sending the body again.

    REDACTED_TOOL_CALL_ARGS_NOTICE = "\n... [%d chars of this old tool call's argument redacted; re-run the tool if you still need them]"

    # What separates one prompt section from the next, and therefore what a
    # patch can be split on when only some sections moved.
    SECTION_SEPARATOR = "\n\n---\n\n"

    # Heads a mid-conversation system message that carries newer text for
    # sections the model was already given. Says what it is and which copy
    # wins, because the request now holds both.
    PROMPT_PATCH_HEADER = "# Prompt Update\n\n" \
                          "Newer text for sections you were given earlier. Where one of them covers the " \
                          "same ground as an earlier section, follow this one."

    # Sent after a truncated answer. It has to be explicit about *not*
    # restarting: a model asked to "continue" will otherwise begin again at
    # the first sentence.
    # Frozen because it is read inside session Ractors: a non-shareable
    # constant raises Ractor::IsolationError there, which used to kill
    # post-answer learning (memory extraction and feedback) on every turn.
    CONTINUE_PROMPT = <<~PROMPT.strip.freeze
      Your previous message was cut off mid-sentence because it reached the
      output limit. Continue exactly where it stopped, starting with the
      remaining words of the interrupted sentence. Do not repeat anything you
      already wrote, do not start over, and do not add a preamble.
    PROMPT

    # Sent when the model finished a tool round without saying anything at all,
    # which leaves the user with silence and no images or files.
    #
    # It names the one file tool on purpose. It used to name only the
    # single-file tool, and a batch of five pictures then arrived as five
    # separate calls: the model followed the name this sentence mentioned.
    ANSWER_NOW_PROMPT = <<~PROMPT.strip.freeze
      You ran the tools above but produced no answer. Using their results,
      reply to the user now, in the user's language. If they asked for files or
      images, send them before you finish with one `send_files` call — one path
      for a single file, every path for a batch.
    PROMPT

    # Sent when a reply came back with no visible text at all — on a reasoning
    # model the whole output budget can go to the hidden reasoning, leaving an
    # empty `content`. Nothing was sent to the user, so it is asked again.
    EMPTY_ANSWER_PROMPT = <<~PROMPT.strip.freeze
      Your previous reply contained no text the user could read (the output
      budget was spent before any of it was written). Answer the user's last
      message now, directly and as briefly as the question allows.
    PROMPT

    # Recorded for tool calls that were never run because the user stopped the
    # turn. The provider requires exactly one result per tool call, so the
    # skipped calls still get an answer in the transcript.
    CANCELLED_TOOL_RESULT = "ERROR: cancelled by user (/stop); this tool was not executed."

    # How many of one assistant message's tool calls run at the same time. A
    # batch is normally two or three reads; the cap only keeps a runaway batch
    # from opening one process per call.
    MAX_PARALLEL_TOOLS = 4

    # Before/after text kept on a write's tool message so the TUI can redraw
    # its diff when the session is resumed. Skipped for very large files: the
    # session file should not grow by a megabyte for one write.
    MAX_UI_DIFF_CHARS = 120_000

    # Cap on the original task statement injected into the system prompt. A
    # huge pasted request should not crowd out the transcript on every round.
    MAX_TASK_CHARS = 6_000

    # Appended to the answer when a turn is stopped early.
    STOP_NOTICE = "⏹️ Stopped by user."

    # How a lead agent is told about delegation. Kept in the shipped rules so
    # the prompt epoch moves when this text changes (see SystemPrompt#rules).
    DELEGATION_RULE = <<~PROMPT.strip.freeze
      # Delegating to Other Agents

      `delegate` hands a self-contained task to another persona, which has its
      own model, prompt, memory and workspace. The sub agent cannot delegate
      further.

      Delegate when the task is big enough to be worth its own context. Any one
      of these is enough:

      - it touches more than a few files, or more than one area of the code
      - it needs outside reading or research before it can be worked on
      - it is plainly another persona's work: review, debugging, tests, docs,
        or research
      - it is large enough to be written as one self-contained brief without
        asking the user anything back

      When it is unclear whether the work is that big, delegate.

      Do not delegate a task that needs the conversation you are having now, a
      change to a single small file, or a question you can answer directly.
      Say in one line what was delegated and to whom, then fold the result into
      your answer rather than repeating it.

      In a channel where delegation runs in the background, `delegate` returns
      as soon as the run has started and the run keeps working after your turn
      ends. Its answer is read with `subagent_results`: call it when you need
      the answer, or to check whether anything came back before you finish.
      Each answer is handed over once.

      Built-in sub agents (always available, not listed as personas):
      - code_reviewer: review a diff for bugs, security and style
      - debugger: find the cause of an error and the smallest fix
      - researcher: look up docs or references with source URLs
      - test_writer: write and run Ruby minitest cases
      - docs_writer: draft English README and AGENTS.md sections
      - planner: break a task into ordered, actionable steps

      You may also delegate to any of the user's own personas by slug.
    PROMPT

    # Running the calls of one tool round lives beside #process, not inside it:
    # see agent/tool_execution.rb.
    include ToolExecution

    # The phases of a turn: prepare, finish, and the round loop. See
    # agent/turn_loop.rb.
    include TurnLoop

    # Running a task in another persona's workspace, and the audits and progress
    # events that come with it. See agent/subagents.rb.
    include Subagents

    # What a turn cost and how much of the window it left. See
    # agent/usage_accounting.rb.
    include UsageAccounting

    attr_reader :config, :provider, :session, :tools, :soul, :memory, :agents_file, :skill_registry, :safety_guard, :session_model, :persona, :active_preset_name

    # Cancellation token for the turn currently running on this agent. The
    # session actor swaps in the token its watcher thread listens on.
    attr_accessor :cancellation

    # Set by the channel (through the session actor) so a sub agent's progress
    # can be shown live. A Proc that crosses no Ractor boundary: it is built
    # inside the actor from shareable ports, like the other callbacks.
    attr_accessor :on_subagent

    # Same idea for automatic compaction: a Proc built inside the actor that
    # receives the plain-data result of a compaction, so a channel can draw the
    # seam in its timeline. `on_compaction_start` fires just before the
    # summarizer request goes out, which is the part that takes time; a channel
    # uses it to show that compaction is in progress. Manual /compact happens at
    # rest and has no turn to draw into, so only the automatic path calls them.
    attr_accessor :on_compaction, :on_compaction_start, :on_compaction_failed

    # Optional provider (or callable taking the persona slug) used for sub
    # agents. Production leaves it nil so each sub agent builds its own from
    # the target persona's config; tests inject a fake to avoid the network.
    attr_accessor :subagent_provider

    # A channel that can run a delegated agent somewhere other than this turn's
    # thread — the web channel, which runs each run in its own session actor —
    # sets this. `spawn_subagent` then hands the request over instead of running
    # it, and the turn is free to end. Left nil, delegation stays synchronous,
    # which is what the TUI and Telegram still want.
    attr_accessor :on_delegate

    def initialize(config:, provider: nil, session_id: "default", tools: nil, persona: nil,
                   archive: nil)
      @config = config
      # Handle on the SQLite archive (see StoreClient). nil means the session
      # keeps living in its JSON file — the fallback when the archive cannot be
      # opened.
      @archive = archive
      @cancellation = Cancellation.new
      # Text the user typed while a turn was already running (TUI steering).
      # The turn consumes it between rounds; a mutex keeps the reader thread
      # from tearing the list that the turn thread is draining.
      @steering = []
      @steering_mutex = Mutex.new
      # Delegation counters are per turn, reset at the start of #process. The
      # depth is carried into a sub agent so it cannot spawn another one.
      @subagent_depth = 0
      @subagent_count = 0
      @subagent_mutex = Mutex.new
      @subagent = false
      @persona = Persona.from(persona)
      # Auto mode: the preference lives in config.yml and is remembered across
      # launches; the setter writes it back.
      @auto_approve = config.respond_to?(:auto_approve) ? config.auto_approve : false
      @session = Session.new(session_id, workspace: config.workspace,
                                         sessions_dir: session_dir_for(config),
                                         cwd: session_cwd_for(config),
                                         archive: @archive)
      apply_initial_preset!
      @provider = provider || build_provider(preset: @active_preset, effort: thinking_level)

      # Build safety guard from config
      @safety_guard = SafetyGuard.new(
        workspace: config.workspace,
        restrict_to_workspace: config.restrict_to_workspace,
        allow_read_outside: config.allow_read_outside_workspace
      )

      @tools = tools || Tools::Registry.new
      # Always inject safety guard into tools, even when passed from outside
      inject_safety_guard
      inject_tool_workspace
      inject_tool_context

      # Warn if safety guard is disabled
      unless @safety_guard.restrict_to_workspace
        warn "[safety] WARNING: restrict_to_workspace is DISABLED — agent has full system access"
        warn "[safety] Set restrict_to_workspace: true in config.yml to enable sandboxing"
      else
        mode = @safety_guard.allow_read_outside ? "restrict-write" : "strict"
        warn "[safety] Safety guard ENABLED (mode: #{mode}, workspace: #{@safety_guard.workspace})"
      end

      # Identity, memory, rules and skills come from the configured workspace,
      # even when the channel re-roots the working directory (the TUI takes the
      # directory it was launched from). Otherwise launching in a project would
      # silently drop all of them.
      assets = config.assets_workspace
      @soul = Soul.new(workspace: assets)
      @memory = build_memory(config)
      # AGENTS.md is project rules, so a file in the working directory wins;
      # the configured workspace's copy is the fallback (and is what the
      # Telegram bot always uses, since its workspace is that directory).
      @agents_file = AgentsFile.new(workspace: agents_workspace(config, assets))
      # Skills live in the shared directory (~/.rubot/skills), not in the
      # workspace: a persona re-roots the workspace at its own directory and
      # the TUI re-roots it at the project, so a workspace-relative tree would
      # be copied once per persona. Older installs kept them in the workspace;
      # those are still read, after the shared directory.
      @skill_registry = SkillRegistry.new(workspace: config.skills_workspace,
                                          extra_workspaces: config.legacy_skills_workspaces)
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
    #   on_tool_call:     Called before each tool executes. Yields (tool_name, arguments,
    #                     ui_snapshot) — the file's before-content when this call is
    #                     about to change a file, nil otherwise. Taken here, inside
    #                     whatever thread or Ractor runs the tool, because a caller
    #                     that reads the file after hearing about the call is racing
    #                     the tool: a delete finishes before the snapshot is taken.
    #   on_tool_result:   Called after each tool executes. Yields (tool_name, result,
    #                     ui_diff) — { "path", "before", "after" } for a file that
    #                     changed, nil otherwise. Both payloads travel with the
    #                     event so a channel only has to render them.
    #   on_progress:      Called after each full round. Yields (round_count, tool_count).
    #   on_usage:         Called with fresh usage report data as soon as a request's
    #                     tokens are recorded and after every round's tool results,
    #                     so a channel can update cost/cache/context mid-turn.
    #   on_confirm:       Called before dangerous actions that could cause data loss.
    #                     Yields (tool_name, arguments, reason) — reason is a
    #                     short phrase like "deletes files" or "overwrite
    #                     build.log — 412 of 900 lines would be lost", or nil
    #                     when the tool has no better description. Return
    #                     truthy to proceed, falsy to skip. Not called at all in
    #                     auto mode.
    #   on_assistant_text: Called with the model's own words whenever it replies
    #                     with text *and* tool calls (progress narration, e.g.
    #                     "Let me check the structure first."). Channels forward
    #                     this to the user as a regular message while work continues.
    #                     Yields (text).
    #   on_stopped:       Called once when the turn ended because the user
    #                     stopped it, before the stop notice is appended.
    #   on_steer:         Called with a message the user queued while the turn
    #                     was running, at the moment it is handed to the model.
    #   on_reasoning:     Called with each fragment of the model's thinking as
    #                     it streams in, before the answer starts. Channels use
    #                     it to show a live "thinking" block; nothing is called
    #                     for a model that does not stream its reasoning.
    def process(message, on_tool_call: nil, on_tool_result: nil, on_progress: nil, on_confirm: nil,
                on_assistant_text: nil, on_reasoning: nil, on_steer: nil, on_stopped: nil, on_usage: nil,
                on_subagent: nil, on_compaction: nil, on_compaction_start: nil, on_compaction_failed: nil, on_retry: nil,
                on_delegate: nil, stream: true, &on_chunk)
      # One object for what this turn reports back, so the phases below name the
      # callback they use instead of carrying fifteen keywords each.
      callbacks = TurnCallbacks.new(tool_call: on_tool_call, tool_result: on_tool_result,
                                    progress: on_progress, confirm: on_confirm,
                                    assistant_text: on_assistant_text, reasoning: on_reasoning,
                                    steer: on_steer, stopped: on_stopped, usage: on_usage,
                                    subagent: on_subagent, delegate: on_delegate,
                                    compaction: on_compaction, compaction_start: on_compaction_start,
                                    compaction_failed: on_compaction_failed,
                                    retry_callback: on_retry)
      turn, cron_results = prepare_turn(message, callbacks)
      response, reasoning_content = run_rounds(turn, callbacks, stream: stream, &on_chunk)
      finish_turn(turn, callbacks, cron_results: cron_results, response: response,
                  reasoning_content: reasoning_content)
    ensure
      @cancellation.finish!
      Thread.current[:rubot_cancellation] = nil
    end

    # Ask the running turn to stop before its next provider call or tool
    # execution. Safe to call from another thread; idle agents ignore it.
    def cancel!
      @cancellation.cancel!
    end

    # Queue text for the turn that is already running, without blocking the
    # caller. It is delivered between rounds: after the current round's tool
    # calls, before the next provider call. Returns false when the message is
    # blank, so a caller can keep it in the prompt instead of losing it.
    def steer(message)
      text = message.to_s.strip
      return false if text.empty?

      @steering_mutex.synchronize { @steering << text }
      true
    end

    # Oldest queued steering message, consumed exactly once. Safe to call from
    # any thread.
    def take_steering
      @steering_mutex.synchronize { @steering.shift }
    end

    def steering_pending?
      @steering_mutex.synchronize { !@steering.empty? }
    end

    def cancelled?
      @cancellation.cancelled?
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
    # Model ids reported by the provider's /models endpoint, cached for the
    # lifetime of this agent. Used as a fallback when config.yml does not list
    # any models, and merged into the TUI model picker.
    def provider_model_entries
      @provider_model_entries ||= begin
        ids = @provider.respond_to?(:list_models) ? @provider.list_models : []
        Array(ids).filter_map do |id|
          text = id.to_s.strip
          next if text.empty?

          { "name" => text, "model" => text }
        end
      rescue StandardError
        []
      end
    end

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
      @provider = routed(settings.with_effort(thinking_level))
      @session_model
    end

    # Switch the reasoning effort ("thinking level") for this session. nil or
    # "" drops the session's own choice, so the persona's default — or the
    # effort its preset carries — takes over again. The provider is rebuilt so
    # the very next request carries the new effort.
    def use_thinking(level)
      text = level.to_s.strip.downcase
      text = nil if text.empty?
      return nil if text && !Persona::THINKING_LEVELS.include?(text)

      before = thinking_level
      @session.thinking_level = text
      @session.save!
      # Only rebuild when the effort actually moves. A rebuild builds a new
      # provider, and with it a new routing identity for the gateway's prompt
      # cache: paying that on a setting that did not change is a full cache
      # miss for a no-op, which is how a form that re-submits the current
      # level wiped the prefix on every turn.
      @provider = build_provider(preset: @active_preset, effort: thinking_level) unless thinking_level == before
      text
    end

    # The reasoning effort this session runs on: its own choice first, then the
    # persona's default, then the effort its preset or the config carries.
    # nil means "send no effort at all", which is what the providers did before
    # the choice existed.
    def thinking_level
      @session.thinking_level || @persona&.thinking ||
        @active_preset&.dig("reasoning_effort") || @config.reasoning_effort
    end

    # The models the provider supports, from its /models catalog. The list is
    # cached (in memory and on disk), so an unreachable provider does not
    # empty the picker. Providers that cannot list models return [].
    def provider_models
      model_catalog.entries
    end

    # The memoized provider catalog.
    def model_catalog
      @model_catalog ||= ModelCatalog.new(config: @config)
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
        # The epoch below is what actually rebuilds the prompt, but the pin is
        # dropped here too: a persona change must never depend on every future
        # persona field remembering to join the fingerprint.
        @session.clear_system_prompt!
        @session.save!
        inject_tool_persona
        return nil
      end

      @persona = persona
      @session.model_override = nil
      inject_tool_persona

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

      # A different persona is a different prompt, and the pin is dropped even
      # when the model it landed on happens to be the same one.
      @session.clear_system_prompt!
      @session.save!
      persona_info
    end

    alias set_persona apply_persona

    # Switch to a different session (e.g. per-topic in Telegram).
    # Applies the saved preset for that session, falling back to the topic's
    # persona or the configured default preset.
    def switch_session(session_id)
      return @session if @session.id == session_id
      @session = Session.new(session_id, workspace: @config.workspace,
                                         sessions_dir: session_dir_for(@config),
                                         cwd: session_cwd_for(@config),
                                         archive: @archive)
      apply_initial_preset!
      @session
    end

    # Auto mode: run anything the safety guard allows without asking first.
    # What it skips is the question, never the guard — the destructive
    # patterns in SafetyGuard are checked inside each tool and stay refused.
    def auto_approve?
      @auto_approve == true
    end

    # Turn auto mode on or off. The choice is written to config.yml, so the
    # next launch starts in the same mode.
    def auto_approve=(value)
      @auto_approve = !!value
      @config.set_auto_approve(@auto_approve) if @config.respond_to?(:set_auto_approve)
      @auto_approve
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
      info[:auto_approve] = true if auto_approve?
      info[:skills] = @skill_registry.count if @skill_registry.any?
      info[:adaptive] = "memory+batched-extraction+summary+feedback"
      info
    end

    # Force a compaction of the current session transcript, regardless of the
    # automatic threshold. Used by /compact. Returns plain data so it can
    # cross a Ractor boundary, or nil when there is nothing to compact.
    #
    # `protect_current_turn` is what the mid-turn callers ask for: the messages
    # of the turn being executed are never summarized away, because the turn
    # still needs them (the file it just read, the edit it just made, the
    # failing command it is about to fix). Summarizing them keeps a paragraph
    # about the work and drops the work itself, which is what a long turn that
    # suddenly re-explores the repo looks like from the outside. /compact at
    # rest keeps the plain rule: there is no turn to protect.
    def compact_session(protect_current_turn: false)
      # A long transcript splits into dozens of summarizer batches. Give the
      # session a factory so it can fan them out over a few workers, each with
      # its own provider instance (a provider carries per-request state that
      # would race if shared). The settings come from the conversation's own
      # provider, so the model and routing are unchanged; only the concurrency
      # is new. Callers that inject a fake provider have no config to build
      # from, so they keep the serial path.
      factory = compaction_provider_factory
      if @config.token_based_compaction?
        result = @session.compact!(
          provider: @provider,
          keep_recent_tokens: @config.compact_keep_recent_tokens,
          min_keep: protect_current_turn ? current_turn_message_count : nil,
          system_prompt: build_system_prompt,
          provider_factory: factory
        )
      else
        keep = protect_current_turn ? compaction_keep_recent : @config.compact_keep_recent_messages
        result = @session.compact!(
          provider: @provider,
          keep_recent: keep,
          system_prompt: build_system_prompt,
          provider_factory: factory
        )
      end
      return nil unless result

      # Both callers want the seam remembered: the automatic path draws it in
      # the live turn, and a manual /compact has no turn to draw into but still
      # leaves a mark in the transcript a refresh reads back. Recording here
      # keeps the two paths from writing the same event twice.
      @session.record_compaction(result)

      # Compaction drops messages from the front, so the mark that says where
      # this turn began has to move with them. Left alone it points past the
      # end of a shrunken transcript, `current_turn_message_count` collapses to
      # zero, and the rest of the turn is sent without its own reasoning.
      if @turn_start_index
        @turn_start_index = [ @turn_start_index - result[:summarized_messages].to_i, 0 ].max
      end
      result
    end

    # How many messages compaction has to keep verbatim: the configured window,
    # or the whole turn in flight when that is longer.
    def compaction_keep_recent
      [ @config.compact_keep_recent_messages.to_i, current_turn_message_count ].max
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

    # A tool whose answer is a card has nothing for the model to say. Without
    # this the model narrates the click and then writes a closing sentence on
    # top of a button the reader can already see.
    SILENT_TOOL_RULE = <<~PROMPT.strip.freeze
      # Tools That Answer Themselves

      The `instagram` tool's `connect` operation draws a Connect card in the
      conversation. When the user asks to connect Instagram, call that tool
      immediately: no sentence before the call, no sentence after it. The card
      is the entire answer. Do not claim the account is connected — the user
      still has to press the button.
    PROMPT

    NARRATION_RULE = <<~PROMPT.strip.freeze
      # Progress Narration

      Before running tools, write one short sentence in the same language as the
      user's message describing what you are about to do and why, for example
      "Let me look at the current structure first." or "Now I'll generate the image."
      Speak in terms of the task, not the tool: never mention tool names, function
      names, JSON arguments, or raw commands in these sentences. The user sees the
      sentence as a chat message while you work.

      # One Message, Every Call That Is Ready

      Every message you send costs a full round trip, and the reader waits through
      all of them. So narrate once, then issue every tool call whose arguments you
      already know in that same message: reading four files, checking three paths,
      or running two searches whose patterns are already clear is one message with
      four calls, not four messages. Call a tool alone only when its arguments
      depend on a result you do not have yet. Never split work into separate
      messages just to report progress between them.
    PROMPT

    # The same rule again, at the very end of the prompt. Placement is the
    # point: an instruction read immediately before the question is the one a
    # model follows most reliably, and this is the instruction that decides how
    # many round trips a turn costs.
    BATCH_REMINDER = <<~PROMPT.strip.freeze
      # Before You Send

      Count the tool calls you are about to make. If one of them does not need
      another's result, they belong in the same message: one message, every call
      that is already possible.
    PROMPT

    # Handing files back to the user. Kept here rather than left to the tool
    # descriptions alone: the model decides which tool to call before it reads
    # a description for guidance, and it reaches for the name it already knows.
    # A batch asked for as one instruction has to arrive as one call.
    FILE_DELIVERY_RULE = <<~PROMPT.strip.freeze
      # Sending Files

      `send_files` hands local files to the user in one call. Pass `paths` with
      every file the user asked for — one entry for a single file, several for
      a batch. One call sends them together instead of one round trip per file.
      Images (.png, .jpg, .jpeg, .webp, .gif) are delivered as pictures so they
      display inline; videos (.mp4, .webm, .mov) play inline too. Other files
      arrive as documents, and in the browser a PDF or a markdown note gets a
      card that opens in a tab.

      Up to ten paths fit in one call; past that, send a second batch rather
      than falling back to one call per file.
    PROMPT

    # Editing files through the file tool, not shell. Kept here (not in the
    # configurable prompt) so a per-topic persona cannot drop it.
    FILE_EDIT_RULE = <<~PROMPT.strip.freeze
      # Editing Files

      Change an existing file with the file tool's `edit` operation: read the
      part you need, then replace an exact `old_string` with `new_string`. Use
      enough surrounding lines for `old_string` to be unique. Use `write` only
      when creating a file or genuinely rewriting all of it, and `append` to
      add to the end.

      Read with `offset`/`limit` when a file is long; the reply says which lines
      came back, so continue from there instead of re-reading the whole file.

      Avoid shell commands that edit files in place (`sed -i`, `perl -i`,
      stdout redirection into a file, `tee`). Files changed through the file
      tool are shown to the user as a before/after diff and confirmed —
      in-place shell edits bypass that review. Deleting a file goes through
      the file tool as well (`operation: delete`): its diff shows every line
      that went away, while `rm` would remove the file with nothing on screen.
      Shell is for what the file tool cannot do: searching (`grep`), renaming,
      moving, copying, and running what already exists.

      When an edit succeeds, report it briefly — which file you updated and
      what changed in one sentence — and stop there. Do not reconstruct the
      change in your reply in any form: no file contents, no +/- diff lines,
      no before/after comparison, no canned code excerpt. The terminal
      already renders the exact git-style diff under the tool row; repeating
      it just floods the chat. Only quote the few lines you are actually
      discussing.
    PROMPT

    # When a finished turn may ring the user's phone.
    #
    # The rule is the request, not the clock and not the agent's own judgement:
    # a turn ends on the screen where it was typed, so announcing one unprompted
    # only repeats what the reader already sees. The single exception is a
    # standing request — the user asking, in their own words, to be told at the
    # end of every turn — because that is a preference about their devices and
    # nothing about this particular turn can stand in for it.
    NOTIFY_RULE = <<~PROMPT.strip.freeze
      # Announcing the End of a Turn

      A turn ends where the user is already looking, so a notification nobody
      asked for tells them what is on their screen. Never call the `notify`
      tool on your own initiative — not for long work, not for work they are
      waiting on, not because a notification would be nice.

      Call it when the user asked to be told that this work is finished
      ("kabari kalau sudah kelar", "tell me when you are done"). The
      announcement carries `message` if you pass one, otherwise the opening of
      your answer, and it arrives when the turn ends.

      One request overrides this: when the user themselves asked to be
      notified at the end of every turn, call `notify` at the end of every
      turn from then on, without waiting to be asked again. Nothing else
      counts as that request.
    PROMPT

    # The system prompt for this request.
    #
    # Pinned for the life of the session rather than rebuilt every time (see
    # Session#system_prompt_for): it sits at the front of every request, so
    # rebuilding it meant a one-line memory edit cost a full uncached re-read
    # of the whole conversation. SystemPrompt#compose does the actual work.
    def build_system_prompt
      epoch = system_prompt.epoch
      pinned = @session&.system_prompt_for(epoch)
      return pinned if pinned

      prompt = compose_system_prompt
      @session&.store_system_prompt(prompt, epoch)
      prompt
    end

    # Drop the pinned prompt so the next request builds it again.
    #
    # This is the way out of the pin, and the only one a reader has: memory
    # written since the session started, an edited skill file, a changed
    # AGENTS.md — none of them reach a running session until the epoch moves
    # (compaction, a model switch, a persona change). Asking for it costs one
    # uncached request: the prefix changes, so nothing in front of the change is
    # reusable. That is the trade, and it is why this is a deliberate request
    # rather than something that happens on every memory write.
    # Append a system-level addition without rewriting the cached prefix.
    # Skeleton: only supported providers/models opt in; otherwise fall back to
    # repin. The delta computation is intentionally left to a follow-up.
    def append_system_addition(text)
      return repin_system_prompt unless mid_conversation_system?

      return false if text.to_s.strip.empty?
      if @session.respond_to?(:add_system_addition)
        @session.add_system_addition(text.to_s)
      else
        @session.add("system", text.to_s) if @session.respond_to?(:add)
      end
      true
    end

    # True when this provider takes a `role: "system"` message in the middle of
    # a conversation without losing the cached prefix in front of it. Measured
    # on the OpenCode Go gateway: a system message inserted before the last
    # user turn answered 200, and the request after it still reported the
    # cached tokens.
    def mid_conversation_system?
      @provider.respond_to?(:supports_mid_conversation_system?) && @provider.supports_mid_conversation_system?
    end

    # Pick up whatever changed since the prompt was pinned.
    #
    # Dropping the pin is the honest way to make the model see new memory, and
    # it costs the whole prefix: the system prompt is at the front, so a
    # rebuilt one re-reads every token behind it — 25k to 29k in the sessions
    # measured. Where the provider takes a mid-conversation system message,
    # the same news arrives as a patch at the back: the sections that changed,
    # and nothing in front of them re-read.
    def repin_system_prompt
      return false unless @session

      pinned = @session.system_prompt_for(system_prompt.epoch)
      if pinned && mid_conversation_system?
        patch = system_prompt.patch(pinned, composed: compose_system_prompt)
        # Nothing new is worth a request: a refresh that finds no change is a
        # no-op, not a reason to burn the cache.
        return patch.nil? ? false : @session.set_system_patch(patch)
      end

      @session.clear_system_prompt!
    end

    # The builder the rest of this class asks: what the prompt says, and what it
    # is made of. A new one per call rather than a kept one, because it holds no
    # state of its own — every input is read from the agent as it composes.
    def system_prompt
      SystemPrompt.new(self)
    end

    # The prompt itself, composed from its sources (see SystemPrompt#compose).
    def compose_system_prompt
      system_prompt.compose
    end

    # Stable identity for a piece of text across restarts. Used for the cache
    # record, which has to name what a request was made of.
    def digest_of(text)
      system_prompt.digest_of(text)
    end

    # Learn from the turn that just finished. Channels call this *after* they
    # have delivered the answer, so extraction never delays a reply.
    #
    # A failure here must never cost the user their answer, so everything is
    # rescued and reported through the debug log only.
    def flush_learning
      run_session_naming
      run_feedback_learning
      run_memory_extraction
    rescue StandardError => e
      warn "[adaptive] learning failed: #{e.class}: #{e.message}"
    end

    private

    # Where this agent's session files go, and the directory they are marked as
    # coming from. Both come from the config so a channel can re-root them: the
    # TUI keeps one central sessions directory while recording the project it
    # was launched in, and /resume filters on that recorded directory.
    def session_dir_for(cfg)
      cfg.respond_to?(:sessions_dir) ? cfg.sessions_dir : Session.sessions_dir(cfg.workspace)
    end

    def session_cwd_for(cfg)
      cfg.respond_to?(:sessions_cwd) ? cfg.sessions_cwd : nil
    end

    # Global memory next to config.yml plus the memory of the workspace this
    # agent works in — which for a persona is the persona's own MEMORY.md.
    # Configs that predate the split (tests, plain data configs) fall back to
    # the single file in the assets workspace.
    def build_memory(cfg)
      unless cfg.respond_to?(:global_memory_path) && cfg.respond_to?(:workspace_memory_path)
        return Memory.new(workspace: cfg.assets_workspace)
      end

      label = cfg.respond_to?(:memory_scope_label) ? cfg.memory_scope_label : MemoryBank::SCOPE_WORKSPACE
      MemoryBank.new(
        global_path: cfg.global_memory_path,
        workspace_path: cfg.workspace_memory_path(cfg.workspace),
        workspace_label: label
      )
    end

    # Directory holding the AGENTS.md this agent follows. The project's own
    # file is preferred over the global one in the configured workspace, so
    # running the TUI inside a repo picks up that repo's rules.
    def agents_workspace(config, assets)
      project = config.workspace
      if project && File.exist?(File.join(project, "AGENTS.md"))
        project
      else
        assets
      end
    end

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
      @provider = build_provider(preset: @active_preset, effort: thinking_level)
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
      @provider = routed(settings.with_effort(thinking_level))
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
      # The install's own jobs live next to config.yml (~/.rubot/cron), not
      # inside the workspace the agent works in.
      cron_tool.store_root = @config.catalog_dir if cron_tool.respond_to?(:store_root=)
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

    # Tell tools where relative paths belong. The web channel roots the config
    # at the persona's directory and the TUI at the configured workspace, so
    # this is the one place that knows the right answer for both.
    def inject_tool_workspace
      return unless @tools.respond_to?(:all)
      @tools.all.each do |tool|
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
      @tools.all.each do |tool|
        tool.store_port = port if port && tool.respond_to?(:store_port=)
      end
      inject_tool_persona
    end

    def inject_tool_persona
      return unless @tools.respond_to?(:all)

      slug = @persona&.slug.to_s
      @tools.all.each do |tool|
        tool.persona = slug if tool.respond_to?(:persona=)
      end
    end

    # The delegate tool needs a handle back to this agent to do the spawning.
    # Set at the start of every turn, like the persona stamp, because the tool
    # registry is shared between agents in the same Ractor.
    def inject_tool_delegate
      return unless @tools.respond_to?(:all)

      %w[delegate subagent_results].each do |name|
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

    def build_messages
      messages = []

      # Add system prompt (composed from all sources)
      messages << { "role" => "system", "content" => build_system_prompt }

      # Add conversation history (limited by messages and, optionally, tokens).
      # `reasoning_tail` keeps reasoning only for the turn being executed.
      recent_messages = @session.safe_history(
        reasoning_tail: current_turn_message_count
      )

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

      # Append system additions without rewriting the cached prefix.
      if @session.respond_to?(:system_additions)
        @session.system_additions.each do |addition|
          messages << { "role" => "system", "content" => addition }
        end
      end

      # Newer text for sections the model was pinned with. Last on purpose: it
      # has to read closer to the question than what it supersedes, and it sits
      # behind the transcript, so a change here costs the block and nothing in
      # front of it.
      patch = @session.respond_to?(:system_patch) ? @session.system_patch : nil
      messages << { "role" => "system", "content" => patch } if patch

      messages
    end

    # Number of messages that belong to the turn currently running. Used to
    # decide which reasoning blocks are still worth sending.
    def current_turn_message_count
      return 0 if @turn_start_index.nil?

      [ @session.messages.size - @turn_start_index, 0 ].max
    end


# Replace oversized top-level string values in an old tool call's
# arguments with a notice, on the request copy only (the session transcript
# keeps the originals). Values are rebuilt through merge/map because
# conversation_history shares the stored tool_calls arrays by reference —
# mutating them in place would corrupt the session file.
def redact_old_tool_call_args!(messages, tool_call_id, max_chars)
  return unless tool_call_id

  index = messages.index do |m|
    m["role"] == "assistant" && m["tool_calls"]&.any? { |tc| tc["id"] == tool_call_id }
  end
  return unless index

  message = messages[index]
  calls = message["tool_calls"].map do |tc|
    next tc unless tc["id"] == tool_call_id

    args = tc.dig("function", "arguments").to_s
    redacted = redact_json_args(args, max_chars)
    next tc if redacted == args

    tc.merge("function" => tc["function"].merge("arguments" => redacted))
  end
  messages[index] = message.merge("tool_calls" => calls)
end

# Keep the first `max_chars` of each oversized top-level string value and
# note how much was dropped, so the model still sees paths and command
# shapes without carrying whole file bodies. Arguments that are not valid
# JSON are left alone: a malformed string in history is what the provider
# already accepted once, and guessing at its shape risks more.
def redact_json_args(args, max_chars)
  parsed = JSON.parse(args)
  return args unless parsed.is_a?(Hash)

  changed = false
  parsed.each do |key, value|
    next unless value.is_a?(String) && value.length > max_chars

    parsed[key] = value[0...max_chars] +
      format(REDACTED_TOOL_CALL_ARGS_NOTICE, value.length - max_chars)
    changed = true
  end
  changed ? JSON.generate(parsed) : args
rescue JSON::ParserError
  args
end

    # Build a provider from an immutable settings snapshot. No config
    # mutation is performed, so this is safe to call from any Ractor.
    def build_provider(model_name = nil, preset: nil, effort: nil)
      settings = if preset
        @config.provider_settings_for_preset(preset)
      else
        @config.provider_settings(model_name)
      end
      settings = settings.with_effort(effort) unless effort.nil?
      routed(settings)
    end

    # Build a provider that belongs to this session.
    #
    # The gateway keys its prompt cache on the routing header the provider
    # sends, and a provider built from config alone had no conversation to
    # stamp it with, so it invented one. Every rebuild therefore looked like a
    # brand-new conversation to the cache, even though the model was answering
    # the same one — the measured cost was a prompt that fell back to the
    # pinned prefix alone (4,480 tokens) in the middle of a session.
    def routed(settings)
      settings = settings.with_session_key(@session.id) if settings.respond_to?(:with_session_key) && @session
      Provider.build(settings)
    end

    # Rebuild the provider using the session-level model override.
    def rebuild_provider
      return if @session_model.nil?
      return if @config.model_entry_by_name(@session_model).nil? && !provider_model_id?(@session_model)

      @provider = build_provider(@session_model, effort: thinking_level)
    end

    # A model from the provider's /models catalog rather than config.yml.
    def provider_model_id?(name)
      id = name.to_s
      return true if ModelCatalog.cached_model_ids(@config.catalog_dir).include?(id)
      return true if provider_model_entries.any? { |entry| entry["name"].to_s == id }

      # The catalog loaded in this process knows its ids without a fetch.
      @model_catalog&.cached_ids.to_a.include?(id)
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

    # The names a request may call, which is what a prompt sentence can safely
    # name: `tools_enabled` can switch the whole set off, and a config can trim
    # it further.
    def tool_names
      (tool_definitions || []).map(&:name)
    end

    # Tools a sub agent must never call: delegating again (recursion), ringing
    # the user, scheduling jobs or drawing an Instagram card from a background
    # worker would all be surprising. A sub agent does its work and returns a
    # written result; the lead stays the one voice the user hears.
    SUBAGENT_FORBIDDEN_TOOLS = %w[delegate subagent_results notify cron instagram].freeze

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

      # Reading what a background run came back with is part of delegating, not
      # a feature of its own: a config that lists its tools by hand and enables
      # `delegate` would otherwise collect answers with no way to read them. The
      # sub agent filter below still takes it away from the sub agents
      # themselves.
      if tools.any? { |tool| tool.name == "delegate" }
        results_tool = @tools.get("subagent_results")
        tools += [ results_tool ] if results_tool && !tools.include?(results_tool)
      end

      if @subagent
        tools = tools.reject { |t| SUBAGENT_FORBIDDEN_TOOLS.include?(t.name) }
        if @persona&.internal
          allowed = SubagentRegistry.allowed_tools(@persona.slug)
          tools = tools.select { |t| allowed.include?(t.name) } if allowed
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
    # Before-content of a file a file_ops write/append/edit/delete is about to
    # touch. nil for reads and every other tool.
    def file_ui_snapshot(tool_name, arguments)
      return nil unless tool_name == "file_ops" && arguments.is_a?(Hash)
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
      history = @session.safe_history()
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

    # -- Public methods accessible from background threads and channels --
    public

    # Process a cron message through the LLM. Called by the cron scheduler's
    # background thread.
    #
    # `fresh` starts a transcript from nothing but the system prompt, for jobs
    # that want a conversation of their own: a daily practice session should
    # not inherit yesterday's subject, and a long-running reminder should not
    # drag the history it was created in behind it.
    def process_cron(message, fresh: false)
      process_background(message, fresh: fresh, label: "⏰ Scheduled task fired:\n")
    end

    # A turn the reader did not speak.
    #
    # The text reaches the model as context and nothing of it is written to the
    # transcript: only the answer is. A fired job arrives this way, and so does
    # the report a finished batch of sub agents leaves behind — the reader asked
    # for the work, not for a message in their own voice.
    #
    # A block given to this method is handed the answer as it is written, one
    # call per passage. A background turn is exactly the one nobody is watching,
    # so a channel that can show it arriving does — otherwise the reader waits
    # through the whole answer in silence and then reads it all at once.
    def process_background(message, fresh: false, label: "", &on_chunk)
      # Build local messages from session history ONLY (up to the last assistant response)
      # Do NOT include the current user message — this is a separate conversation turn
      @turn_start_index = @session.messages.size
      local_messages = build_background_messages(fresh: fresh)
      local_messages << { "role" => "user", "content" => "#{label}#{message}" }

      response = ""
      tool_calls = nil
      reasoning_content = nil
      rounds = 0
      limit = max_rounds

      loop do
        break if rounds >= limit

        # A fired job runs on this agent's own persona, but the tool registry is
      # shared — stamp the scope before the turn reaches any tool.
      inject_tool_persona

      # A background turn has no channel callback to report retries to, so pass a
        # no-op rather than the `on_retry` local from #process — that variable
        # is not in scope here and used to raise NameError on every fired job.
        result = if block_given?
          # The answer accumulates here as well as in the provider: what the
          # reader is shown is the passage so far, not the fragment that just
          # arrived, so a repaint can never lose a word.
          @provider.chat_stream(local_messages, tools: tool_definitions, on_retry: nil) do |chunk, _tools, _reasoning|
            response += chunk if chunk
            on_chunk.call(response.dup) if chunk && !chunk.empty?
          end
        else
          @provider.chat(local_messages, tools: tool_definitions, on_retry: nil)
        end
        # A background run is a separate, local transcript: count its tokens and cost,
        # but never let it become the anchor for /context's context size.
        record_usage(result, auxiliary: true, messages: local_messages)

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

          # A background turn has no guard to ask and nobody watching, so the
          # calls are collected and run together like a normal turn's.
          cron_calls = tool_calls.map do |tc|
            tool_name, arguments, = parse_tool_call(tc)
            tool_call_id = tc.is_a?(Hash) ? (tc["id"] || tool_name) : tool_name
            { name: tool_name, arguments: arguments, id: tool_call_id }
          end

          execute_tool_calls(cron_calls).each do |call|
            local_messages << { "role" => "tool", "content" => call[:result], "tool_call_id" => call[:id] }
          end

          response = ""
          tool_calls = nil
          rounds += 1
        else
          break
        end
      end

      # An empty answer falls back to the text that was handed in: something
      # has to stand in the transcript, and the request says more than "".
      response = message if response.nil? || response.strip.empty?

      # The answer carries a stamp so the transcript can give it a block of its
      # own (see the page's history): nothing prompted it, and glued under the
      # answer above it read as if it had never arrived.
      unless response.empty?
        @session.add("assistant", response, reasoning_content: reasoning_content, background: true)
      end
      response
    end

    # Name a conversation that was opened without one. A cron job that starts
    # its own session has no user message for the name to come from, so without
    # this every run would sit in the sidebar as "Untitled session" and the days
    # would be impossible to tell apart.
    def set_session_title(title)
      text = title.to_s.strip
      return nil if text.empty?

      @session.title = text
      @session.save!
      @session.title
    end

    # Build messages for a background turn — uses conversation history
    # but excludes the current user message being processed.
    #
    # With `fresh: true` the history is left out entirely: the system prompt is
    # the whole context, which is what a job that opens its own conversation
    # needs.
    def build_background_messages(fresh: false)
      messages = []
      messages << { "role" => "system", "content" => build_system_prompt }
      return messages if fresh

      all_history = @session.safe_history(
        reasoning_tail: 0
      )

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
      provider = auxiliary_provider
      extracted = @memory_extractor.extract(batch, provider: provider)

      # Extraction is a real provider request; count it in the session totals
      # without overwriting `last_usage`, which `/context` uses for context size.
      if @memory_extractor.last_usage
        @session.record_auxiliary_usage(
          @memory_extractor.last_usage, provider: provider.name,
          rates: auxiliary_rates
        )
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

    # Give the conversation a name, once.
    #
    # A session file holds a transcript, not a name, and the prompt that opened
    # it is written for the agent rather than for a list someone scans. One
    # small request names it after the answer has been delivered, so naming
    # never delays the reply; its tokens are recorded as auxiliary usage so the
    # context figure the status row shows stays about the conversation itself.
    def run_session_naming
      return unless @session.title.to_s.strip.empty?

      prompt = first_user_prompt
      return if prompt.nil?

      namer = SessionNamer.new(provider: auxiliary_provider)
      title = namer.name(prompt, reply: first_assistant_answer)

      if namer.last_usage
        @session.record_auxiliary_usage(
          namer.last_usage, provider: auxiliary_provider.name,
          rates: auxiliary_rates
        )
      end
      return if title.nil?

      @session.title = title
      @session.save!
      warn "[session_namer] named #{@session.id}: #{title}" if Rubot.debug?
    end

    # The prompt that opened this conversation, ignoring the instructions rubot
    # sends itself.
    def first_user_prompt
      @session.messages.each do |msg|
        next unless msg["role"] == "user"

        content = msg["content"].to_s.strip
        next if content.empty?
        next if [ CONTINUE_PROMPT, ANSWER_NOW_PROMPT, EMPTY_ANSWER_PROMPT ].include?(content)

        return content
      end
      nil
    end

    # What the conversation turned into, which is often easier to name than the
    # request that started it. nil when the first turn produced no text.
    def first_assistant_answer
      msg = @session.messages.find { |m| m["role"] == "assistant" && !m["content"].to_s.strip.empty? }
      msg && msg["content"].to_s
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
    #
    # Both branches run in the middle of a turn, so both hand the turn in flight
    # to compact_session as something it may not summarize.
    def run_auto_compaction
      return unless @config.auto_compact?
      min_keep = @config.token_based_compaction? ? 2 : @config.compact_keep_recent_messages
      return if @session.message_count <= min_keep

      window = context_window_tokens
      # An unknown model used to disable compaction entirely, which left an
      # unbounded transcript and a silently trimmed request. Fall back to a
      # conservative window so there is always a bound.
      window = Config::DEFAULT_CONTEXT_WINDOW unless window.to_i.positive?

      threshold = window * (@config.compact_threshold_percent / 100.0)
      cap = @config.compact_threshold_tokens
      threshold = [ threshold, cap ].min if cap.positive?
      used = estimated_context_tokens
      return if used < threshold

      # The summarizer call is the slow part, and it happens inside compact!.
      # Announce it before entering so the reader sees "in progress" while the
      # provider is working, not only once the result is already in hand.
      @on_compaction_start&.call
      result = compact_session(protect_current_turn: true)
      if result
        @on_compaction&.call(result)
      else
        # The "in progress" row was already drawn. Without this the reader is
        # left staring at it forever when the summarizer fails or finds nothing
        # to do, because the success callback is the only thing that retires it.
        @on_compaction_failed&.call
      end
      if result && Rubot.debug?
        warn "[compaction] auto: #{result[:summarized_messages]} messages summarized, " \
             "context #{result[:context_before]} -> #{result[:context_after]} tokens (estimated)"
      end
      result
    end
  end
end
