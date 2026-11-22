# frozen_string_literal: true

module Rubot
  class Agent
    # What a turn cost, and how much of the window it left.
    #
    # These methods read the provider's usage block, price it against the
    # configured rates, and keep the session's running figures. They are here
    # rather than beside the provider loop because they are the part of a turn
    # a channel draws separately: the footer can ask for fresh numbers in the
    # middle of a round, and none of that needs to know which round is running.
    #
    # Moved as it was, comments included. A wrong figure is worse than a slow
    # one: the pricing precedence below is the contract.
    module UsageAccounting
      # Approximate size of the next request: transcript + system prompt. Uses
      # the latest provider usage as the anchor when it is still valid, exactly
      # like /context, so compaction and the footer agree.
      def estimated_context_tokens
        context_usage[:tokens]
      end

      # Context window of the active model, or nil when it cannot be resolved.
      def context_window_tokens
        preset = @active_preset || {}
        model_id = preset["model"] || @session_model || @config.model
        provider_name = preset["provider"] || @provider.name
        resolve_context_window(model_id, provider_name, preset)
      end

      # Token accounting and cost estimate for the current session.
      # Returns plain data (symbol keys, numbers, strings) so it can cross a
      # Ractor boundary from a SessionActor.
      #
      # `network: false` is the mid-turn path: figures that are already known,
      # without a models.dev lookup a running turn must not wait on.
      #
      # `live` carries provisional numbers for a request that has not come back
      # yet (see #process): `prompt_tokens` is the size of the request in flight
      # and `output_tokens` the answer streamed so far. They are estimates, and
      # the report says so, so a channel can show a figure that moves.
      def usage_report(network: true, live: nil)
        preset = @active_preset || {}
        model_id = preset["model"] || @session_model || @config.model
        provider_name = preset["provider"] || @provider.name

        window = resolve_context_window(model_id, provider_name, preset)
        rates, price_source = resolve_rates(model_id, provider_name, preset, network: network)
        context = context_usage
        usage = @session.usage
        last = @session.last_usage
        provisional = live.is_a?(Hash)
        live_prompt = provisional ? live[:prompt_tokens].to_i : 0
        live_output = provisional ? live[:output_tokens].to_i : 0

        # What the next request will carry while this one is still streaming:
        # the request that just went out plus the answer arriving now.
        if provisional
          context = { tokens: live_prompt + live_output, anchored: context[:anchored] }
        end

        {
          model: active_model_name,
          model_id: model_id,
          provider: provider_name,
          context_used: context[:tokens],
          context_anchored: context[:anchored],
          context_window: window,
          context_percent: window.to_i.positive? ? context[:tokens].to_f / window * 100 : nil,
          messages: @session.message_count,
          requests: usage.requests,
          # While a request is in flight its tokens are not measured yet; the
          # provisional ones are added on top of what the session has recorded.
          prompt_tokens: usage.prompt_tokens + live_prompt,
          completion_tokens: usage.completion_tokens + live_output,
          cached_tokens: usage.cached_tokens,
          cache_creation_tokens: usage.cache_creation_tokens,
          # Like Pi, the headline cache figure describes the latest request, not
          # the session total: that is what shows whether the cache is working
          # now instead of on average since the conversation started.
          cache_hit_rate: last.requests.positive? ? last.cache_hit_rate : 0.0,
          # The session-wide share, published next to the latest-request one
          # because the cost beside them is cumulative. A lone "cache 4%" under a
          # $2 total reads as a contradiction; the pair shows the history that
          # produced the bill and the request that is running now.
          cache_hit_rate_session: usage.requests.positive? ? usage.cache_hit_rate : 0.0,
          # Cache share of the last few requests, oldest first. A run of zeros is
          # the signature of a prefix that moves on every request; a single zero
          # after a compaction is expected. Without this a reader can only see the
          # latest request and has to guess which one it is looking at.
          cache_history: @session.cache_history.dup,
          # Why the latest request missed, when it did: a label derived from the
          # last two records, not a guess (see CacheDiagnosis). nil means the
          # latest request hit and there is nothing to explain.
          cache_cause: CacheDiagnosis.cause(@session.cache_records),
          last_prompt_tokens: last.prompt_tokens,
          # The part of the last request that was paid at the full input rate:
          # what the prefix churn actually cost. It is the figure a miss is felt
          # in, and the one to watch when testing a change.
          last_re_read_tokens: [ last.prompt_tokens - last.cached_tokens - last.cache_creation_tokens, 0 ].max,
          total_tokens: usage.total_tokens + live_prompt + live_output,
          # Priced per request when it was recorded, so switching model mid-way
          # does not re-price earlier turns. Legacy session files have no stored
          # cost; price their totals with the current rates instead. A total that
          # missed a request (no rates yet on the first turn) is re-priced too.
          # The session's cost hash is mutated in place on every request, so a
          # report hands out a copy: a caller that keeps an earlier figure (the
          # live footer does) must not see it change underneath.
          cost: build_cost(usage, rates, live_prompt, live_output,
                           last.requests.positive? ? last.cache_hit_rate : 0.0),
          # True while part of the figure is estimated from a request that has
          # not returned yet. A channel can mark it instead of passing it off as
          # a measured number.
          provisional: provisional,
          price_source: price_source
        }
      end

      # Session cost, plus the in-flight request's contribution when there is
      # one. The in-flight input is priced with the previous request's cache
      # share as the assumption: prompt caching makes the prefix of a growing
      # conversation the cached part, so pricing it all as uncached would show a
      # figure that collapses the moment the real usage lands.
      def build_cost(usage, rates, live_prompt, live_output, cached_share = 0.0)
        stored = (@session.cost && !@session.cost_partial?) ? @session.cost.dup : Usage.cost(usage, rates)
        return stored if stored.nil?

        # Sessions priced before `saved` existed keep their totals; the saving is
        # derived from them rather than left blank.
        stored["saved"] ||= Usage.cached_savings(usage, rates) if rates
        return stored if live_prompt.zero? && live_output.zero?

        live = Usage.new(prompt_tokens: live_prompt, completion_tokens: live_output,
                         cached_tokens: (live_prompt * cached_share.to_f).round)
        extra = Usage.cost(live, rates)
        return stored unless extra

        merged = %w[input cached_input cache_creation output total saved].each_with_object({}) do |key, acc|
          acc[key] = stored[key].to_f + extra[key].to_f
        end
        # The flag describes the rates, not the request, so it survives the sum:
        # a figure built from an unknown cache-read rate stays an upper bound.
        if stored["cache_price_unknown"] || extra["cache_price_unknown"]
          merged["cache_price_unknown"] = true
        end
        merged
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

      private

      # Persist the provider's usage for this request. Streaming providers may
      # return the usage inside the result hash; otherwise read last_usage.
      # `auxiliary` is for requests that are not the user-facing turn (cron,
      # memory extraction, summarization): they count toward the totals without
      # replacing the context anchor.
      def record_usage(result, auxiliary: false, messages: nil)
        raw = result.is_a?(Hash) ? result["usage"] : nil
        raw ||= @provider.last_usage if @provider.respond_to?(:last_usage)
        return if raw.nil?

        rates = current_rates(network: false)
        shape = cache_request_shape(messages, auxiliary: auxiliary)
        if auxiliary
          @session.record_auxiliary_usage(raw, provider: @provider.name, rates: rates, shape: shape)
        else
          @session.record_usage(raw, provider: @provider.name, rates: rates, shape: shape)
        end
      rescue StandardError => e
        warn "[usage] Failed to record usage: #{e.class}: #{e.message}" if @config.debug?
      end

      # The request as the prompt cache sees it: a digest of the pinned system
      # prompt, a digest of the tool catalog, how many blocks the provider will
      # hash, and how many turns the live window carried.
      #
      # Digests rather than copies, because the question they answer is only ever
      # "is this the same as last time?". A hit rate says a request missed; the
      # first record whose digest differs says where the prefix moved — the system
      # prompt, the tools, or the history in front of the cache breakpoint.
      #
      # `blocks` counts what a provider hashes as separate pieces: the system
      # prompt, each tool definition, each message. Anthropic's lookback window is
      # measured in blocks (twenty of them), so this is the number that tells a
      # growing conversation whether it has walked past the last cache write.
      #
      # The per-block `fingerprint` and `diverged_at` narrow the same question to
      # one block: the whole-prompt digest says the history changed, the
      # fingerprint says which message. Both are computed from the list that was
      # actually sent (`messages`), not from the session, so a trimmed window is
      # fingerprinted as it went out.
      def cache_request_shape(messages, auxiliary: false)
        tools = tool_definitions || []
        system_prompt = build_system_prompt
        sent = messages || @session.messages
        fingerprint = CacheProbe.fingerprint(system: system_prompt, tools: tools, messages: sent)
        previous = @session.cache_records.last
        diverged_at = CacheProbe.first_divergence(previous && previous["fingerprint"], fingerprint)
        kind, role = diverged_block(diverged_at, tools: tools, messages: sent)
        {
          "provider" => @provider.name.to_s,
          "model" => active_model_name.to_s,
          "epoch" => digest_of(system_prompt),
          "tools" => digest_of(tools.map { |tool| [ tool.name, tool.description, tool.parameters ] }.to_json),
          "blocks" => CacheProbe.block_count(fingerprint),
          "turns" => sent.size,
          "fingerprint" => fingerprint,
          "diverged_at" => diverged_at,
          "diverged_kind" => kind,
          "diverged_role" => role,
          "summary" => digest_of(@session.summary_text.to_s),
          "effort" => thinking_level.to_s,
          "auxiliary" => auxiliary
        }
      end

      # What sits at the block the fingerprint broke on: the system prompt, one
      # tool definition, or a message with a role. Recorded with the request
      # because only here is the sent list still in hand — a later reader would
      # have to guess the boundary between tools and messages from counts that a
      # trim in the same request can move.
      def diverged_block(diverged_at, tools:, messages:)
        return [ nil, nil ] unless diverged_at.is_a?(Integer) && diverged_at >= 0

        return [ CacheProbe::SYSTEM, nil ] if diverged_at.zero?
        return [ CacheProbe::TOOL, nil ] if diverged_at <= tools.size

        message = messages[diverged_at - tools.size - 1]
        return [ CacheProbe::MESSAGE, nil ] if message.nil?

        [ CacheProbe::MESSAGE, message["role"].to_s ]
      end

      # Publish live figures to a caller that wants them mid-turn. Failing to
      # produce a footer must never cost the user their answer, so every error
      # here is swallowed after a debug note.
      def emit_usage(callback, live: nil)
        return unless callback

        callback.call(usage_report(network: false, live: live))
      rescue StandardError => e
        warn "[usage] Failed to publish live usage: #{e.class}: #{e.message}" if @config.debug?
      end

      # Rate lookup for the model this agent is currently talking to. The turn
      # path passes `network: false` so a slow models.dev never delays an answer.
      def current_rates(network: true)
        preset = @active_preset || {}
        model_id = preset["model"] || @session_model || @config.model
        provider_name = preset["provider"] || @provider.name
        resolve_rates(model_id, provider_name, preset, network: network).first
      end

      # The provider for the requests that are not the conversation: naming a
      # session, extracting memory. Unset `auxiliary_model` returns the
      # conversation's own provider, so a config that says nothing behaves
      # exactly as before. Built once per agent and then reused, because a
      # provider is a connection pool, not a value.
      # A factory for the summarizer's parallel workers. Each call builds a fresh
      # provider from the conversation provider's immutable settings, so batches
      # never share the last-usage or cancellation state. Returns nil when there
      # is nothing to build from (an injected fake provider in tests), which
      # leaves the session on its serial path.
      def compaction_provider_factory
        # Use the conversation's own provider settings, not the auxiliary model.
        # A fast auxiliary model is tempting for a job this large, but it can
        # refuse batches made mostly of tool output by answering with empty
        # content, which makes the whole compaction fail and leaves the context
        # unchanged. The parallelism below is where the speed comes from; the
        # model has to be one that actually summarizes every batch.
        settings = @provider.respond_to?(:config) ? @provider.config : nil
        return nil if settings.nil?

        -> { Provider.build(settings) }
      end

      def auxiliary_provider
        settings = @config.auxiliary_settings
        return @provider if settings.nil?

        # Deliberately unstamped: these requests carry a different prompt
        # (a summary, an extraction), and sending them under the conversation's
        # routing header would let the gateway's cache store them as that
        # conversation's prefix — the one route this agent needs left alone.
        @auxiliary_provider ||= Provider.build(settings)
      end

      # What those requests cost, priced against the model that served them. A
      # cheap auxiliary model billed at the conversation's rate would make the
      # saving invisible in the session totals.
      def auxiliary_rates
        name = @config.auxiliary_model
        return current_rates(network: false) if name.nil?

        settings = @config.auxiliary_settings
        preset = @config.model_preset(name) || {}
        resolve_rates(settings.model, settings.provider, preset, network: false).first
      end

      # Context estimate for the next request. The system prompt is only needed
      # when there is no usable usage anchor (fresh session, after compaction),
      # because an anchor already includes the prompt it was sent with.
      def context_usage
        if @session.context_anchored?
          @session.context_tokens
        else
          @session.context_tokens(extra_chars: build_system_prompt.length)
        end
      end

      def pricing_catalog
        @pricing_catalog ||= PricingCatalog.new(config: @config)
      end

      def resolve_context_window(model_id, provider_name, preset)
        # Presets inherit `context_window_tokens` from their model entry, so
        # there is no need to consult another model's entry here (doing that
        # leaked the default model's window into a switched-to preset).
        value = preset["context_window_tokens"].to_i
        return value if value.positive?

        pricing_catalog.context_window(model_id, provider: provider_name) ||
          ModelInfo.context_window(model_id) ||
          estimated_context_window(model_id)
      end

      # A model id the catalog does not know exactly (a gateway suffix like
      # "hy4-flash-free" for "hy4") still has a window: match the longest known
      # id that starts the name. Without this the context meter silently
      # disappears for every aliased model, which reads as a broken panel rather
      # than a missing catalog entry.
      def estimated_context_window(model_id)
        id = ModelInfo.normalize(model_id)
        return nil if id.empty?

        known = pricing_catalog.context_window_ids
        match = known.select { |candidate| id.start_with?(candidate) }
                     .max_by(&:length)
        match && pricing_catalog.context_window(match)
      end

      def resolve_rates(model_id, provider_name, preset, network: true)
        configured = ModelInfo.normalize_rates(preset["pricing"])
        return [ configured, "config" ] if configured

        if provider_name.to_s == "ollama"
          return [ { "input" => 0.0, "output" => 0.0, "cached_input" => 0.0,
                     "cache_creation_input" => 0.0 }, "free" ]
        end

        catalog_rates = pricing_catalog.rates(model_id, provider: provider_name, network: network)
        return [ catalog_rates, pricing_catalog.source ] if catalog_rates

        builtin = ModelInfo.rates(model_id, provider: provider_name)
        builtin ? [ builtin, "builtin" ] : [ nil, nil ]
      end
    end
  end
end
