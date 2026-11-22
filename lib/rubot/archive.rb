# frozen_string_literal: true

module Rubot
  # The archive a process is currently writing to.
  #
  # A Store is opened once, in the main Ractor, and every channel then reads it
  # through `Session.store`. That accessor was set from one place and read from
  # thirty, which made the archive look like a property of Session rather than
  # what it is: one install-wide service that a channel borrows. This module is
  # the only name callers use, so the question "who holds the archive" has one
  # answer in one file, and the day it needs to move (a second store, a
  # read-only one for search) only this file changes.
  #
  # Deliberately still backed by `Session.store`: the value has to be visible to
  # the code that already reads it, including the JSON fallback path, and moving
  # the variable would change when a half-booted process sees nil.
  module Archive
    module_function

    # The open archive, or nil when this process has none (the TUI and the REPL
    # keep their sessions as JSON files, and a failed open falls back to that).
    def current
      Session.store
    end

    # Hand the archive to the rest of the process, or drop it on shutdown.
    def current=(store)
      Session.store = store
    end
  end
end
