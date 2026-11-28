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
require_relative "tool_names"
require_relative "safety_guard"
require_relative "soul"
require_relative "memory"
require_relative "agents_file"
require_relative "tools/memory_tool"
require_relative "memory_extractor"
require_relative "agent/background"
require_relative "agent/loops"
require_relative "agent/message_builder"
require_relative "agent/model_selection"
require_relative "agent/prompt_pinning"
require_relative "agent/subagents"
require_relative "agent/system_prompt"
require_relative "agent/tool_execution"
require_relative "agent/tool_wiring"
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
    # The number is read by a human, and the three figures move by a tenth at a
    # time: twice a second still reads as live, and it is half the events a
    # channel has to render and send (the web footer re-sends its row on each
    # one, and those events also break up a burst of streamed chunks).
    LIVE_USAGE_INTERVAL = 0.5

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

    # Sent when a loop iteration reaches its round cap. The turn gets this one
    # last request with no tools, so it ends with a report of what it did and
    # what is left instead of a call cut off halfway. The rule about tool calls
    # is not decoration: with no tools on offer, a model that tries to call one
    # anyway has written it into the answer, and the next iteration would read
    # it as prose.
    LOOP_CLOSE_OUT_PROMPT = <<~PROMPT.strip.freeze
      You have reached this iteration's round cap, so no more tool calls can run.
      Do not call any tool. In a few sentences, say what you finished, what is
      still undone, and exactly where the next iteration should pick up.
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
      - implementer: make a described code change, run the tests, report the diff
      - researcher: look up docs or references with source URLs
      - test_writer: write and run Ruby minitest cases
      - docs_writer: draft English README and AGENTS.md sections
      - planner: break a task into ordered, actionable steps

      You may also delegate to any of the user's own personas by slug.
    PROMPT

    # When a loop is the right tool and when it is a bill. Kept in the shipped
    # rules so the prompt epoch moves when this text changes (see
    # SystemPrompt#rules).
    LOOP_RULE = <<~PROMPT.strip.freeze
      # Loops: Work That Needs Several Attempts

      `loop` works a goal through repeated iterations, one commit per iteration
      in a git worktree that belongs to the loop and never to your checkout.

      Use it only for work that needs several attempts to finish and has a
      checkable definition of done. Never for a single edit: one tool call does
      that better and leaves nothing behind to clean up.

      Every loop gets its own worktree, so state the repo path, the goal and the
      done_criteria precisely. A loop that stops as stalled or stuck should be
      reported, not restarted blindly: the state file says what the last
      iterations tried, and that is what the user needs to hear.
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

    # Asking the channel to work a loop, when no runner can be held here. See
    # agent/loops.rb.
    include Loops

    # What a turn cost and how much of the window it left. See
    # agent/usage_accounting.rb.
    include UsageAccounting

    # The turns nobody is waiting for: cron, learning, naming, compaction. See
    # agent/background.rb.
    include Background

    # Which model answers, and which preset put it there. See
    # agent/model_selection.rb.
    include ModelSelection

    # Stamping this turn's identity on the shared tool registry, and the tool
    # definitions the model is shown. See agent/tool_wiring.rb.
    include ToolWiring

    # The messages one request is made of. See agent/message_builder.rb.
    include MessageBuilder

    # The system prompt a session is pinned to, and the patches that update it.
    # See agent/prompt_pinning.rb.
    include PromptPinning

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

      # The tool list is checked once, here: a misspelling in config fails the
      # build instead of the first turn that asks for tool definitions.
      validate_tool_config!

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
    #   on_ask:           Called when the model asks the user a question through
    #                     ask_user. Yields the question payload — {question:,
    #                     options: [{label:, description:}]} — and returns an
    #                     outcome hash: {outcome: :option, index:, label:},
    #                     {outcome: :custom, text:}, {outcome: :expired} or
    #                     {outcome: :cancelled}. A channel with nowhere to ask
    #                     passes nil, and the tool tells the model to decide.
    def process(message, on_tool_call: nil, on_tool_result: nil, on_progress: nil, on_confirm: nil,
                on_ask: nil,
                on_assistant_text: nil, on_reasoning: nil, on_steer: nil, on_stopped: nil, on_usage: nil,
                on_subagent: nil, on_compaction: nil, on_compaction_start: nil, on_compaction_failed: nil, on_retry: nil,
                on_delegate: nil, on_loop: nil, stream: true, &on_chunk)
      # One object for what this turn reports back, so the phases below name the
      # callback they use instead of carrying fifteen keywords each.
      callbacks = TurnCallbacks.new(tool_call: on_tool_call, tool_result: on_tool_result,
                                    progress: on_progress, confirm: on_confirm, ask: on_ask,
                                    assistant_text: on_assistant_text, reasoning: on_reasoning,
                                    steer: on_steer, stopped: on_stopped, usage: on_usage,
                                    subagent: on_subagent, delegate: on_delegate, on_loop: on_loop,
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

      Change an existing file with `file_write`'s `edit` operation: read the
      part you need with `file_read`, then replace an exact `old_string` with
      `new_string`. Use enough surrounding lines for `old_string` to be unique.
      Use `write` only when creating a file or genuinely rewriting all of it,
      and `append` to add to the end.

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

    # When a question is worth interrupting the user for.
    #
    # The tool's own description says how to ask. This says when, and it says
    # it in the prompt because the rule has to hold even in a turn that never
    # calls the tool: the failure it prevents is a turn that guessed instead of
    # asking, and that turn has no tool call to hang the reminder on.
    ASK_RULE = <<~PROMPT.strip.freeze
      # Asking the User

      When a decision is the user's and you cannot settle it from the code, the
      files or what you already know, ask with `ask_user` instead of guessing.
      Offer 2 to 4 concrete options, best first, and say in one line what
      picking each one means. Never ask something you could look up yourself:
      read the file, run the search, check the config, then ask only what
      remains.

      A guess that would cost the user real work is the case for asking. A
      guess they could shrug off is the case for deciding and saying what you
      assumed.
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

    # Tools a sub agent must never call: delegating again (recursion), ringing
    # the user, scheduling jobs or drawing an Instagram card from a background
    # worker would all be surprising. A sub agent does its work and returns a
    # written result; the lead stays the one voice the user hears.
    # `loop` is on the list because a loop outlives the turn that starts it: a
    # sub agent that opened one would hand back an answer while the work it
    # began kept spending tokens, with nobody watching the file it writes to.
    # Loops are started by a channel, which is where a reader can see them.
    SUBAGENT_FORBIDDEN_TOOLS = %w[delegate subagent_results notify cron instagram loop ask_user].freeze

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

    # What this turn may spend in rounds. An ordinary turn's answer is the one
    # the reader is waiting for, so its ceiling is `max_rounds` (1000 by
    # default) and only a runaway loop reaches it. A loop iteration is a step
    # the loop will ask for again, and every request inside it re-sends the
    # conversation: its ceiling is the loop's own, 40 by default, so one
    # iteration cannot spend a budget on a context it keeps re-reading.
    def turn_round_limit
      loop_iteration_session? ? loop_max_rounds : max_rounds
    end

    def loop_max_rounds
      @config.respond_to?(:loop_max_rounds) ? @config.loop_max_rounds : Config::DEFAULT_LOOP_MAX_ROUNDS
    end

    # How large an iteration's context may get before the turn stops, in tokens.
    # The other half of the same ceiling: an iteration is bounded in rounds and
    # in context, because one request re-sends the whole conversation and a
    # turn that reaches its window has already paid for the transcript many
    # times over.
    def loop_max_context_tokens
      @config.respond_to?(:loop_max_context_tokens) ? @config.loop_max_context_tokens : Config::DEFAULT_LOOP_MAX_CONTEXT_TOKENS
    end

    # What one tool result may weigh in the transcript, in characters, clipped
    # once on the way in (see Rubot::ToolOutput). An ordinary turn clips too:
    # the cost of a re-sent transcript is not a loop's alone.
    def tool_output_max_chars
      @config.respond_to?(:tool_output_max_chars) ? @config.tool_output_max_chars : Config::DEFAULT_TOOL_OUTPUT_MAX_CHARS
    end

    # Whether this session is one turn of a loop's work (see LoopRunner). The id
    # is shaped by the runner -- `loop-<id>~a<stamp>~it<n>` -- and it is the only
    # thing the agent is told: the session is a throwaway, never a conversation
    # the roster lists. The verifier's session ends in `~verify`, so it is not
    # this: a verdict is one question, not an iteration that pays its own way.
    LOOP_ITERATION_SESSION = /\Aloop-.*~it\d+\z/.freeze

    def loop_iteration_session?
      @session.id.to_s.match?(LOOP_ITERATION_SESSION)
    end

    # The round cap an iteration reached, when it reached one: `{ rounds:, limit: }`
    # for the loop's log, nil for a turn that ended on its own. Set at the end of
    # the turn that hit it, so the runner reading the answer can write down what
    # stopped it rather than inferring it from a text.
    attr_reader :last_round_cap

    # The context ceiling an iteration reached, when it reached one:
    # `{ tokens:, limit: }`, read off the last measured request. The same fact as
    # `last_round_cap` for the other ceiling, and the one the loop writes into the
    # entry that says the iteration stopped before sending a transcript it had
    # already paid for.
    attr_reader :last_context_ceiling

    # Five reads a test drives directly, because each is a policy fact and not a
    # step of a turn: `turn_round_limit` is which ceiling this turn is under,
    # `loop_iteration_session?` is what decides it, `last_round_cap` and
    # `last_context_ceiling` are what an iteration reports after it reached one,
    # and `loop_max_context_tokens` is the number the second ceiling compares
    # against. All of them are what the caps and the compaction skip are written
    # in terms of, so a test that proves either has to be able to ask them
    # without a full turn.
    public :turn_round_limit, :loop_iteration_session?, :last_round_cap, :last_context_ceiling,
           :loop_max_context_tokens

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
  end
end
