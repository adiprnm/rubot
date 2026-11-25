# frozen_string_literal: true

module Rubot
  class Agent
    # The system prompt this build sends, and the fingerprint that decides when
    # it has to be rebuilt.
    #
    # Composition order is deliberate: the parts that cannot change during a
    # session come first and the volatile ones last, so a rebuild (a compaction,
    # a model switch, a persona change) still leaves a cacheable prefix in front
    # of the changed block.
    #
    # The builder reads the agent's collaborators — persona, soul, AGENTS.md,
    # skills, memory, session — rather than a copy of them, because they move
    # while a session runs. It is built per request and holds nothing of its
    # own.
    class SystemPrompt
      def initialize(agent)
        @agent = agent
      end

    # The sections of the newly composed prompt that the model has not been
    # given yet, as one patch — or nil when every section is already known.
    #
    # Whole sections rather than a line diff: a section is the unit the prompt
    # is built from, and half a section ("only the new memory line") reads as a
    # fragment without the heading that says what it belongs to. A section that
    # changed arrives in full and supersedes the earlier copy.
    def patch(pinned, composed:)
      known = [ pinned.to_s, Array(session.system_additions).join(SECTION_SEPARATOR), session.system_patch.to_s ]
      fresh = composed.split(SECTION_SEPARATOR)
      changed = fresh.reject { |section| section.strip.empty? || known.any? { |text| text.include?(section) } }
      return nil if changed.empty?

      "#{PROMPT_PATCH_HEADER}\n\n#{changed.join(SECTION_SEPARATOR)}"
    end
    # Fingerprint of the inputs that must reach the model the moment they
    # change. Anything not listed here (a new memory line, an edited skill
    # file, AGENTS.md) waits for the next epoch — that delay is the price of a
    # cacheable prefix, and it is paid once instead of on every request.
    #
    # Memory being frozen for the life of a session is not a loss: memory is
    # how a fact survives into the *next* session, and inside this one the
    # transcript already carries everything that was learned from it. The one
    # moment the transcript stops carrying it is compaction, which rewrites the
    # summary and therefore moves this epoch — so the refresh lands exactly
    # when it is needed.
    def epoch
      {
        "model" => active_model_name.to_s,
        # The rules this build ships are an input like any other. Without them
        # here, adding the batching reminder to the code did nothing for a
        # session already running: its prompt stayed pinned to the text of the
        # older build, so the reminder was written, never sent, and the turn went
        # on making one round trip per tool call. A digest of the shipped text
        # moves the epoch when the code changes it — one uncached request per
        # session, once, which is the price of any changed prefix.
        "rules" => digest_of(rules),
        # A persona is identity, not context: switching to another one (or
        # removing it) changes who is answering, so the prompt has to move on
        # that exact request. Leaving it out meant /persona reset reported the
        # persona gone while the bot kept speaking as the old one — visible
        # whenever the new persona kept the same model, invisible when it did
        # not (the model field moved instead, by luck).
        "persona" => digest_of(identity),
        # Compaction rewrites the summary that the prompt quotes verbatim.
        "summary" => digest_of(session&.summary_text),
        "skill" => session&.forced_skill.to_s,
        # Set from the first user message, so the pin must not survive its
        # arrival (early calls build the prompt before any message exists).
        # It is the anchor, not the statement: while the transcript still
        # carries the statement, this stays empty and the epoch stays put.
        "task" => digest_of(task_anchor)
      }
    end

    # The instruction text this build appends to every prompt. Kept in one place
    # because the epoch digests it: a rule that changes in the code has to move
    # the epoch, or a session that is already running keeps answering under the
    # rules it was pinned with.
    def rules
      [ FILE_DELIVERY_RULE, NOTIFY_RULE, SILENT_TOOL_RULE, DELEGATION_RULE, LOOP_RULE, BATCH_REMINDER ].join("\u0000")
    end

    # The persona parts that reach the prompt: its own instructions and the
    # skills it works with. The name is included because it is how the reader
    # is told who they are talking to — a renamed persona is another one.
    def identity
      return "" unless persona

      [persona.name, persona.system_prompt, Array(persona.skills).join(","),
       Array(persona.disabled_skills).join(",")].join("\u0000")
    end

    # Stable identity for a piece of text across restarts: String#hash is
    # salted per process and would make every launch look like a change.
    def digest_of(text)
      value = text.to_s
      return "" if value.empty?

      Digest::SHA1.hexdigest(value)
    end

    # The task statement as the prompt should carry it: the text once the
    # transcript has lost the message that stated it, nil while it still has
    # it. Both the prompt and its epoch read this, so the anchor appears (one
    # uncached request) exactly when trimming or compaction actually takes the
    # goal away, and never sooner.
    def task_anchor
      return nil unless session&.task_anchor_needed?

      session.task_statement
    end

    # Compose the prompt from its sources. Order is deliberate: the parts that
    # cannot change during a session come first and the volatile ones last, so
    # that when the pin does move (compaction, model switch) the provider still
    # finds a cached prefix in front of the changed block.
    def compose
      skill_registry.reload!
      parts = []
      stable_sections(parts)
      volatile_sections(parts)
      parts.join(SECTION_SEPARATOR)
    end

    private

    # The sections that cannot change while a session runs: rules, soul,
    # persona, skills, model, config. They come first because they are what a
    # provider can cache; see #compose.
    def stable_sections(parts)
      # 1. AGENTS.md rules (behavior guidelines). The file's own "# Agent
      # Rules" heading is stripped so it is not sent twice.
      if agents_file.enabled? && !agents_file.rules.empty?
        rules = agents_file.rules.sub(/\A#\s+Agent Rules\s*\n+/, "")
        parts << "# Agent Rules\n\n#{rules}"
      end

      # 1b. Scripting language (Ruby for anything the bot writes itself)
      parts << SCRIPTING_RULE

      # 1c. Progress narration (channels show this to the user as messages)
      parts << NARRATION_RULE

      # 1d. File edits go through the file tool (diff view + confirmation)
      parts << FILE_EDIT_RULE

      # 1d-bis. A card is the whole answer; no narration around it.
      parts << SILENT_TOOL_RULE if tool_names.include?("instagram")

      # 1e. When a finished turn may announce itself. Only when the tool is
      # there to be called: a prompt that names a tool this agent does not
      # have is an instruction it cannot follow.
      parts << NOTIFY_RULE if tool_names.include?("notify")

      # 1e. A batch of files is one call, not one call per file. Only the
      # delivery tools this agent can actually call are named here.
      delivery_rule = file_delivery_rule
      parts << delivery_rule if delivery_rule

      # 1f. Delegation, only when the tool is available and enabled.
      parts << DELEGATION_RULE if tool_names.include?("delegate") && config.delegation_enabled?

      # 1g. Loops, only when the tool is there to be called.
      parts << LOOP_RULE if tool_names.include?("loop")

      # 2. SOUL.md (personality and identity). SOUL.md ships with its own
      # "# Soul" heading (see Soul::DEFAULT_SOUL), so the file's copy is
      # stripped and the prompt supplies the one heading.
      if soul_text.enabled?
        soul = soul_text.to_s.sub(/\A#\s+Soul\s*\n+/, "")
        parts << "# Soul\n\n#{soul}" unless soul.strip.empty?
      end

      # 2b. Persona (per Telegram forum topic, or a web specialist)
      persona_prompt = persona&.system_prompt.to_s.strip
      unless persona_prompt.empty?
        parts << "# Persona\n\n#{persona_prompt}"
      end

      # 2c. The skills this persona exists to use. Skills themselves are shared
      # (they live in the configured workspace, not in the persona's own
      # directory), so the persona is what says which of them apply here.
      required_skills = Array(persona&.skills)
      unless required_skills.empty?
        parts << "# Required Skills\n\nThis persona works with: #{required_skills.join(', ')}.\n" \
                 "Load them and follow them for everything in this conversation, even when the " \
                 "request looks small enough to answer without one."
      end

      # 2d. Current model identity (so the bot knows which model it's using)
      model_name = active_model_name
      model_entry = config.model_entry_by_name(model_name) || config.active_model_entry
      model_provider = model_entry["model"] || config.model
      parts << "# Current Model\n\nYou are currently running as model: **#{model_name}** (#{model_provider}).\nWhen asked about which model you are, respond with: #{model_name}."

      # 2e. Default/config system prompt. A persona prompt replaces it.
      config_prompt = persona_prompt.empty? ? config.system_prompt : ""
      parts << config_prompt unless config_prompt.empty?
    end

    # Everything that moves while a session runs: the task anchor, loaded
    # skills, a forced skill, the summary, memory, and the batching reminder.
    # Last so a refresh costs the tail; see #compose.
    def volatile_sections(parts)
      # --- Everything below is volatile: it changes while a session runs. ---

      # 3. The instruction that started this session, but only once the
      # transcript no longer carries it. Stored outside the transcript so the
      # hard message trim and compaction cannot delete the goal of a long,
      # multi-step task -- and kept out of the prompt until then, because a
      # second, older request sitting in front of the conversation is a
      # competing instruction, not a reminder (see
      # Session#task_anchor_needed?).
      task = task_anchor
      unless task.nil?
        shown = task.length > MAX_TASK_CHARS ? "#{task[0...MAX_TASK_CHARS]}\n... (task truncated)" : task
        parts << "# Task\n\nThe user's original request for this session:\n\n#{shown}"
      end

      # 4. Skills (specialized instruction sets). The list grows as skills are
      # loaded, so it belongs after the stable block. A persona that switched
      # some off does not get them listed at all: the prompt is where a skill
      # announces itself, so a skill left out here is one the model has no
      # reason to open.
      skill_prompt = skill_registry.to_system_prompt(only: enabled_skill_names)
      parts << skill_prompt unless skill_prompt.empty?
      off_prompt = switched_off_skills_prompt
      parts << off_prompt unless off_prompt.empty?

      # 5. Forced skill — injected directly to skip LLM tool-call overhead.
      # A skill the persona switched off arrives here as a refusal instead, so
      # the user hears "that one is off" rather than silence.
      forced = resolve_forced_skill
      if forced && forced[:refused]
        parts << refused_skill_prompt(forced[:name])
      elsif forced
        parts << "# Active Skill: #{forced[:name]}\n\nYou MUST follow the instructions below for this response:\n\n#{forced[:content]}"
      end

      # 6. Conversation Summary (from session summarization)
      if session&.summary_text
        parts << "# Previous Conversation Summary\n\n#{session.summary_text}"
      end

      # 7. Memory: global (~/.rubot/MEMORY.md) merged with this workspace's.
      # Last because extraction rewrites it after most turns; keeping it at the
      # tail means a refresh costs the tail and not the whole prefix.
      # Learned Corrections already live in MEMORY.md, so they are not injected
      # a second time here — that duplicated ~200 tokens per request for no
      # extra information.
      parts << memory.to_s if memory.enabled?

      # 8. The batching instruction, restated last on purpose. A round trip is
      # the expensive part of a turn, and this model follows the instruction it
      # reads closest to the question: the same rule in the middle of a long
      # prompt produced 1–2 calls per message, repeated here it produced 4 of
      # 4 on the same task. Costs ~30 tokens and buys back seconds per turn.
      parts << BATCH_REMINDER
    end

    # Only name the tool when it is actually enabled: an instruction pointing
    # at a tool the model cannot call is how files stopped being sent at all.
    def file_delivery_rule
      return FILE_DELIVERY_RULE if tool_names.include?("send_files")

      nil
    end
    # Skills this persona leaves switched on, or nil when it has switched none
    # off — nil is what SkillRegistry reads as "every skill", so a persona that
    # never touched the list behaves exactly as before. Read on every prompt
    # build rather than cached, because the registry is shared and a persona is
    # edited while its sessions are open.
    def enabled_skill_names
      return nil if persona.nil? || Array(persona.disabled_skills).empty?

      persona.enabled_skills(skill_registry.names)
    end

    # Skills this persona leaves switched off, as named in its prompt. Empty
    # when it switched none off, and always without the skills it *requires*:
    # those stay on by definition (see Persona#skill_enabled?).
    def switched_off_skill_names
      return [] if persona.nil?

      installed = skill_registry.names.map(&:to_s)
      persona.disabled_skills.map(&:to_s).reject { |name| persona.skills.include?(name) } & installed
    end

    # Leaving a switched-off skill out of the listing is not enough by itself:
    # its SKILL.md is still on disk, so a model told "use the writing skill"
    # can open the file and follow it. This block names what is off and says
    # that insisting does not reopen it.
    def switched_off_skills_prompt
      off = switched_off_skill_names
      return "" if off.empty?

      <<~PROMPT.rstrip
        # Skills Switched Off

        This persona has these skills switched off: #{off.join(", ")}.

        They are unavailable in this session. Do not use them, and do not open their SKILL.md files, even when the user asks for one by name, insists, or points at a path — reading the file and following it counts as using the skill. Answer without it and say plainly that the skill is switched off for this persona and can be turned back on from the persona's skills list.
      PROMPT
    end

    # The forced skill was a switched-off one. The flag is spent, and the turn
    # carries the refusal instead of the skill's instructions.
    def refused_skill_prompt(name)
      <<~PROMPT.rstrip
        # Refused Skill: #{name}

        The user asked to use the skill `#{name}`, but this persona has it switched off. Do not use it and do not open its file. Answer without it, and tell the user it is switched off for this persona and can be turned back on from the persona's skills list.
      PROMPT
    end

    # Resolve the forced skill for the current session, return {name, content} or
    # {name, refused: true}, or nil when nothing was forced.
    # Clears the forced_skill flag after use so it only applies once.
    def resolve_forced_skill
      skill_name = session&.forced_skill
      return nil if skill_name.nil? || skill_name.empty?

      # Clear the flag so it only applies to the next message
      session.forced_skill = nil
      session.save! if session.respond_to?(:save!)

      skill = skill_registry.get(skill_name)
      return nil unless skill && skill.enabled?

      # A skill the persona switched off is refused out loud rather than
      # quietly dropped: /use may name anything the registry knows, not just
      # what is left on, and silently answering without it looks like the
      # request was ignored.
      return { name: skill.name, refused: true } unless persona.nil? || persona.skill_enabled?(skill_name)

      { name: skill.name, content: skill.content }
    end

      # What the composition reads from the agent it belongs to. Nothing here
      # is copied at construction: a session's summary, forced skill and
      # additions move between requests, and the prompt has to follow them.

      attr_reader :agent

      def persona
        agent.persona
      end

      def session
        agent.session
      end

      def config
        agent.config
      end

      def memory
        agent.memory
      end

      def agents_file
        agent.agents_file
      end

      def skill_registry
        agent.skill_registry
      end

      def soul_text
        agent.soul
      end

      def tool_names
        agent.send(:tool_names)
      end

      def active_model_name
        agent.active_model_name
      end
    end
  end
end
