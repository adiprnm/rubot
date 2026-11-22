# frozen_string_literal: true

module Rubot
  class Agent
    # The system prompt a session is pinned to, and the patches that update it.
    #
    # The prompt is composed once and then kept for the life of the session (see
    # SystemPrompt#pinned and Session#system_prompt_for), because it sits at the
    # front of every request and a rebuild costs a full uncached re-read. What
    # this module adds on top of the builder is the pin, the patch that adds
    # newer text behind the transcript, and the accounting of which epoch is
    # pinned.
    #
    # Moved as it was, comments included. The three seams a test stubs —
    # #system_prompt, #compose_system_prompt and #digest_of — are deliberately
    # still real methods here rather than calls inlined into their users.
    module PromptPinning
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
    end
  end
end
