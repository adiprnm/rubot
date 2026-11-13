# frozen_string_literal: true

require "net/http"
require_relative "learning"

module Rubot
  # Base class for all communication channels.
  # Subclass this to implement channels for Telegram, Discord, Slack, web, etc.
  #
  # Each channel is responsible for:
  #   - Receiving messages from users
  #   - Forwarding them to a session actor (or a legacy in-process Agent)
  #   - Sending the response back to the user
  #
  # Channels run in a lifecycle: #start → loop { receive → process → send } → #stop
  #
  # Two modes are supported:
  #   * Actor mode   — pass app_config: (or pool:). Each session gets its own
  #                    Ractor, so no mutable Agent state is shared and no
  #                    locking is required.
  #   * Legacy mode  — pass agent:. Used by unit tests and by callers that
  #                    want a plain in-process Agent.
  class Channel
    attr_reader :agent, :config, :name, :pool

    # How long a shutdown waits for stopped turns to unwind before tearing the
    # pool down anyway. See #stop_running_turns.
    SHUTDOWN_GRACE = 2

    # @param agent [Rubot::Agent, nil] legacy in-process agent
    # @param pool [Rubot::Actors::SessionPool, nil] shared session pool
    # @param app_config [Rubot::Config, nil] configuration used to build a pool
    # @param channel_config [Hash] Channel-specific configuration
    def initialize(agent: nil, pool: nil, app_config: nil, channel_config: {})
      @agent = agent
      @pool = pool
      @app_config = app_config
      @config = channel_config
      @name = self.class.name.split("::").last.downcase
      @running = false
      @cron_events = nil
      @cron_thread = nil
      @owned_pool = false
      @running_handles = {}
      @running_mutex = Mutex.new
      @learning_mutex = Mutex.new
      @learning = nil

      build_pool_if_needed
    end

    # Returns true when sessions are backed by Ractors.
    def actor_mode?
      !@pool.nil?
    end

    # Start the channel. Should block until the channel is stopped.
    # Subclasses must override this.
    def start
      raise NotImplementedError, "#{self.class} must implement #start"
    end

    # Stop the channel gracefully.
    # Subclasses should override this if they need cleanup.
    def stop
      @running = false
      stop_cron_listener
      stop_learning_worker
      shutdown_pool
    end

    # Let queued learning finish, then retire the worker. A memory extraction
    # is a provider request, so the wait is bounded rather than indefinite.
    def stop_learning_worker(timeout: 10)
      return unless @learning

      @learning.stop(timeout: timeout)
    end

    # Clean up finished threads and return the list of active threads.
    # Subclasses managing their own threads should call this periodically.
    def reap_threads(threads)
      threads.reject! { |t| t.join(0) }
      threads
    end

    # Hook called before the agent processes a user message.
    # Override in subclasses to intercept, transform, or block input.
    #
    # Return values:
    #   String         — process this message through the agent
    #   nil            — skip processing silently (returns nil)
    #   [:skip, text]  — skip the agent, return `text` as the response
    #
    # @param message [String] The raw user message
    # @return [String, nil, Array] See above
    def before_process(message)
      # No-op by default; override in subclasses
      message
    end

    # Hook called after the agent generates a response.
    # Override in subclasses to transform or filter the output.
    #
    # @param message [String] The original user message
    # @param response [String] The agent's response
    # @return [String] The final response to send back
    def after_process(message, response)
      # No-op by default; override in subclasses
      response
    end

    # Process a single message through the agent/session actor and return the response.
    #
    # @param message [String] The user's message
    # @param session_id [String, nil] Optional session ID to switch to
    # @param on_tool_call [Proc, nil] Called before each tool call; yields
    #   (tool_name, arguments, ui_snapshot), the file's before-content when the
    #   call is about to change a file
    # @param on_tool_result [Proc, nil] Called after each tool call; yields
    #   (tool_name, result, ui_diff), { "path", "before", "after" } for a file
    #   that changed
    # @param on_progress [Proc, nil] Called after each agent round
    # @param on_confirm [Proc, nil] Called before irreversible actions; yields
    #   (tool_name, arguments, reason) and returns truthy to proceed. Not
    #   called at all in auto mode.
    # @param on_assistant_text [Proc, nil] Called with the model's narration text
    #   whenever it writes a message before running more tools
    # @param on_reasoning [Proc, nil] Called with each fragment of the model's
    #   hidden thinking as it arrives. A channel that shows it must keep the
    #   fragments out of the transcript; they are not the answer.
    # @return [String, nil] The agent's response, or nil if processing was skipped
    def process_message(message, session_id: nil, on_tool_call: nil, on_tool_result: nil, on_progress: nil,
                        on_confirm: nil, on_assistant_text: nil, on_reasoning: nil, on_usage: nil)
      sid = (session_id || "default").to_s
      handle = session_for(sid)

      # Make the per-session handle available to before_process via a thread
      # local. Threads stay inside the channel's Ractor, so this is safe.
      Thread.current[:_rubot_request_agent] = handle
      Thread.current[:_rubot_request_session_id] = sid
      track_running_session(sid, handle)

      result = before_process(message)

      if result.is_a?(Array) && result[0] == :skip
        return after_process(message, result[1].to_s)
      end

      return nil if result.nil?

      response = handle.process(
        result,
        on_tool_call: on_tool_call,
        on_tool_result: on_tool_result,
        on_progress: on_progress,
        on_confirm: on_confirm,
        on_assistant_text: on_assistant_text,
        on_reasoning: on_reasoning,
        on_usage: on_usage
      ) do |chunk|
        on_stream_chunk(chunk) if respond_to?(:on_stream_chunk)
      end

      result = after_process(message, response)

      # The answer has been delivered, so background learning can no longer
      # delay it. A channel that has somewhere better to put that wait hands it
      # to the learning queue; one that does not waits here, as before.
      schedule_learning(handle, sid)

      result
    rescue StandardError => e
      handle_error(e, message)
    ensure
      Thread.current[:_rubot_request_agent] = nil
      Thread.current[:_rubot_request_session_id] = nil
      untrack_running_session(sid, handle)
    end

    # Session id of the message being handled on this thread (if any).
    def request_session_id
      Thread.current[:_rubot_request_session_id] || "default"
    end

    # Post-answer learning — naming the conversation, extracting memory,
    # learning from a correction — is a provider request or two. Doing it on
    # the turn's own thread means the reader waits for work that has nothing
    # left to say about the answer they already have: the "still working" row
    # stays up, the stop button stays a stop button, and a turn that took four
    # seconds feels like twelve. See Rubot::Learning.
    #
    # A channel opts in with #defer_learning? and hears back through
    # #after_learning when the work is done, which is the moment a name written
    # there can be drawn. Everything else keeps the blocking behaviour — which
    # is also what a plain agent with no queue would need.
    def defer_learning?
      false
    end

    # Where a channel says "that session has been learned from now".
    def after_learning(_session_id); end

    def learning
      @learning_mutex.synchronize do
        @learning ||= Learning.new { |session_id| after_learning(session_id) }
      end
    end

    def schedule_learning(handle, session_id)
      return unless handle.respond_to?(:flush_learning)

      unless defer_learning?
        run_learning(handle, session_id)
        return
      end

      learning.submit(session_id) { handle.flush_learning }
    end

    # Wait until the queue has been worked off. For tests and for a shutdown
    # that would rather not cut a memory extraction in half.
    def drain_learning(timeout: 30)
      return unless @learning

      @learning.drain(timeout: timeout)
    end

    def learning_pending?
      !@learning.nil? && @learning.pending?
    end

    def run_learning(handle, session_id)
      handle.flush_learning
    rescue StandardError => e
      # A failure here must never cost the user an answer they already have.
      warn "[learning] #{e.class}: #{e.message}" if Rubot.debug?
    ensure
      begin
        after_learning(session_id)
      rescue StandardError => e
        warn "[learning] after_learning failed: #{e.class}: #{e.message}" if Rubot.debug?
      end
    end

    # Stop the turn currently running in a session. Returns false when
    # nothing was running. Works for both actor-backed sessions and a plain
    # in-process agent.
    def cancel_session(session_id)
      sid = (session_id || "default").to_s
      handle = @running_mutex.synchronize { @running_handles[sid] }
      return false unless handle
      return false unless handle.respond_to?(:cancel!)

      handle.cancel!
    end

    def session_running?(session_id)
      sid = (session_id || "default").to_s
      !@running_mutex.synchronize { @running_handles[sid] }.nil?
    end

    # Hand text to the turn already running in a session, without blocking the
    # caller and without queueing behind that turn. Returns false when nothing
    # is running or the handle cannot steer, so the caller can process the
    # message normally instead of losing it.
    def steer_session(session_id, text)
      sid = (session_id || "default").to_s
      handle = @running_mutex.synchronize { @running_handles[sid] }
      return false unless handle&.respond_to?(:steer)

      handle.steer(text)
    rescue StandardError
      false
    end

    # Returns the per-request handle for the current thread, or the shared
    # agent/default session handle outside process_message.
    def request_agent
      Thread.current[:_rubot_request_agent] || (@pool ? @pool.for("default") : @agent)
    end

    # Resolve a session handle for an explicit session id.
    def session_for(session_id)
      @pool ? @pool.for(session_id) : @agent.for_session(session_id)
    end

    # Called for each streaming chunk from the agent.
    # Override in subclasses to stream responses in real-time.
    #
    # @param chunk [String] A chunk of the streamed response
    def on_stream_chunk(chunk)
      # No-op by default; override in subclasses that support streaming
    end

    # Handle errors during message processing.
    # Override in subclasses for channel-specific error handling.
    #
    # @param error [StandardError] The error that occurred
    # @param message [String] The original message that caused the error
    # @return [String] A user-friendly error message
    def handle_error(error, message = nil)
      msg = if quota_exhausted_error?(error)
        "🚫 Usage quota exhausted. Check your plan/billing or switch to another model."
      elsif rate_limit_error?(error)
        "⏳ Rate limited by the provider. Already retried automatically, please try again in a moment."
      elsif timeout_error?(error)
        "⏱️ The model provider did not respond in time. Please try again."
      else
        "❌ Sorry, an error occurred: #{error.message}"
      end

      warn "[#{@name}] Error processing message: #{error.class}: #{error.message}"
      warn error.backtrace.first(5).join("\n") if Rubot.debug?
      msg
    end

    # A 429 from the provider surfaces as RateLimitError in-process and, in
    # actor mode, as that same class once SessionHandle translates the event.
    def rate_limit_error?(error)
      return false if quota_exhausted_error?(error)
      return true if error.is_a?(Rubot::RateLimitError)

      error.message.to_s.match?(/\b429\b|Rate limited/i)
    end

    # A quota-exhausted error surfaces as QuotaExhaustedError in-process and,
    # in actor mode, as that same class once SessionHandle translates it.
    def quota_exhausted_error?(error)
      return true if error.is_a?(Rubot::QuotaExhaustedError)

      Rubot::Provider.quota_exhausted_text?(error.message)
    end

    # Timeouts surface as Net::*Timeout in-process, but as an ActorError
    # ("Net::ReadTimeout: ...") when the session runs in a Ractor. Match both.
    def timeout_error?(error)
      return true if error.is_a?(Net::ReadTimeout) || error.is_a?(Net::OpenTimeout) ||
                     error.is_a?(Net::WriteTimeout)

      error.message.to_s.match?(/\b(?:Net::(?:Read|Open|Write)Timeout|Errno::ETIMEDOUT)\b/)
    end

    # Whether the channel is currently running.
    def running?
      @running
    end

    # Signal handler registration helper.
    # Registers a handler to gracefully stop this channel on SIGINT/SIGTERM.
    def register_signal_handlers
      %w[INT TERM].each do |signal|
        Signal.trap(signal) do
          warn "\n[#{@name}] Received #{signal}, stopping..."
          stop
        end
      end
    end

    # Start a thread that forwards cron fire events from the CronActor.
    def start_cron_listener(&on_fire)
      return unless @cron_events

      @cron_thread = Thread.new do
        loop do
          event = @cron_events.receive
          break if event == :shutdown
          on_fire.call(event[1]) if event.is_a?(Array) && event[0] == :cron_fire
        end
      rescue Ractor::ClosedError
        nil
      end
    end

    def stop_cron_listener
      return unless @cron_thread

      begin
        @cron_events << :shutdown
      rescue Ractor::ClosedError
        nil
      end
      @cron_thread.join(2)
      @cron_thread = nil
    end

    def shutdown_pool
      return unless @owned_pool

      stop_running_turns
      @pool&.shutdown
      @owned_pool = false
    rescue Ractor::ClosedError, Ractor::RemoteError
      nil
    end

    private

    # A session Ractor must not be torn down while a caller is still blocked
    # receiving on its event port: Ruby 4.0.9 takes SIGSEGV in
    # ractor_port_close when port teardown races a live receiver, which is
    # exactly what a quit during a running turn looks like. Stopping the turns
    # first lets those callers return and stop receiving.
    def stop_running_turns
      handles = @running_mutex.synchronize { @running_handles.values.dup }
      return if handles.empty?

      handles.each do |handle|
        handle.cancel! if handle.respond_to?(:cancel!)
      rescue StandardError
        nil
      end

      deadline = Time.now + SHUTDOWN_GRACE
      while Time.now < deadline && !@running_mutex.synchronize { @running_handles.empty? }
        sleep 0.02
      end
    end

    def track_running_session(session_id, handle)
      @running_mutex.synchronize { @running_handles[session_id.to_s] = handle }
    end

    def untrack_running_session(session_id, handle)
      @running_mutex.synchronize do
        sid = session_id.to_s
        @running_handles.delete(sid) if @running_handles[sid].equal?(handle)
      end
    end

    def build_pool_if_needed
      return unless @pool.nil? && @agent.nil? && @app_config

      @cron_events = Ractor::Port.new
      @pool = Actors::SessionPool.new(config: @app_config, delivery: @cron_events)
      @owned_pool = true
    end
  end
end
