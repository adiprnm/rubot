# frozen_string_literal: true

module Rubot
  # The names the model calls a tool by, in one place.
  #
  # A channel, a confirmation prompt and the diff snapshot all ask the same
  # question — "is this call the one that changes a file?" — and each of them
  # used to spell the answer as a literal. Two literals are two chances to
  # drift, and a branch that stopped matching would fail silently: the write
  # row would render as an unknown tool, the confirmation would not say which
  # file, and no diff would be drawn. The file pair is named here once, and the
  # tools themselves answer `name` from it.
  #
  # Only the two names that are compared against live here. A role's tool list
  # (`SubagentRegistry::CODE_TOOLS`) is data describing what a role may do, not
  # a comparison, so it keeps naming its tools directly.
  module ToolNames
    FILE_READ = "file_read"
    FILE_WRITE = "file_write"
  end
end
