# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/rubot"

# Reset the class-level rate limiter before each test to prevent
# cross-test pollution from SafetyGuard's shared timestamp array.
module Minitest
  class Test
    alias_method :original_run, :run
    def run
      Rubot::SafetyGuard.class_variable_set(:@@exec_timestamps, [])
      original_run
    end
  end
end
