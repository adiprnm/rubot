# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"

# The actor tests intentionally exercise Ractors.
Warning[:experimental] = false if Warning.respond_to?(:[]=)

require_relative "../lib/rubot"
