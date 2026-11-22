# frozen_string_literal: true

require "test_helper"
require "rubot"

# Learning and cancellation as the channel sees them: when it defers a summary, and what a stop does.
class TestChannelLearningHook < Minitest::Test
  # Minimal handle that records the order of delivery and learning.
  class RecordingHandle
    attr_reader :events

    def initialize(events)
      @events = events
    end

    def process(_message, **_callbacks)
      @events << :answered
      "answer"
    end

    def flush_learning
      @events << :learned
    end
  end

  class HookChannel < Rubot::Channel
    def initialize(handle, events)
      @handle = handle
      @events = events
      super()
    end

    def name
      "hook"
    end

    def after_process(_message, response)
      @events << :delivered
      response
    end

    def session_for(_session_id)
      @handle
    end

    def start; end
    def stop; end
  end

  def test_learning_runs_after_the_answer_is_delivered
    events = []
    handle = RecordingHandle.new(events)
    channel = HookChannel.new(handle, events)

    response = channel.process_message("hello there")

    assert_equal "answer", response
    assert_equal [ :answered, :delivered, :learned ], events
  end

  # A channel that can announce a later change itself does not make the reader
  # wait for the naming request: the turn ends with the answer, and the queue
  # reports back when it is done.
  class DeferringChannel < HookChannel
    def defer_learning?
      true
    end

    def after_learning(session_id)
      @events << [ :learned_later, session_id ]
    end
  end

  def test_a_deferring_channel_ends_the_turn_before_learning_runs
    events = []
    handle = RecordingHandle.new(events)
    handle.define_singleton_method(:flush_learning) do
      sleep 0.05
      events << :learned
    end
    channel = DeferringChannel.new(handle, events)

    assert_equal "answer", channel.process_message("hello there")
    assert_equal [ :answered, :delivered ], events,
                 "the turn must be finished before the naming request runs"

    channel.drain_learning
    assert_equal [ :answered, :delivered, :learned, [ :learned_later, "default" ] ], events
  ensure
    channel&.stop_learning_worker
  end

  def test_learning_that_fails_still_tells_the_channel_it_is_done
    events = []
    handle = RecordingHandle.new(events)
    handle.define_singleton_method(:flush_learning) { raise "provider said no" }
    channel = DeferringChannel.new(handle, events)

    channel.process_message("hello there")
    channel.drain_learning

    assert_equal [ :answered, :delivered, [ :learned_later, "default" ] ], events
  ensure
    channel&.stop_learning_worker
  end
end

# /stop routing: the channel must be able to reach the turn that is running.
class TestChannelCancellation < Minitest::Test
  class StoppableHandle
    attr_reader :started, :cancelled

    def initialize
      @started = Queue.new
      @done = Queue.new
      @cancelled = false
    end

    def process(_message, **_callbacks)
      @started << true
      @done.pop
      "stopped"
    end

    def cancel!
      @cancelled = true
      @done << true
      true
    end

    def flush_learning
      nil
    end
  end

  class CancelChannel < Rubot::Channel
    def initialize(handle)
      @handle = handle
      super()
    end

    def session_for(_session_id)
      @handle
    end

    def start; end
    def stop; end
  end

  def test_cancel_session_reaches_the_running_turn
    handle = StoppableHandle.new
    channel = CancelChannel.new(handle)
    response = nil

    runner = Thread.new { response = channel.process_message("do something long") }
    handle.started.pop

    assert channel.session_running?("default")
    assert channel.cancel_session("default")
    assert runner.join(5)

    assert_equal "stopped", response
    assert handle.cancelled
    refute channel.session_running?("default")
  end

  def test_cancel_session_without_a_running_turn_returns_false
    channel = CancelChannel.new(StoppableHandle.new)

    refute channel.cancel_session("default")
  end
end
