# frozen_string_literal: true

module Rubot
  # Settings that have to be in a long lived rubot child's environment before
  # its Ruby starts, rather than something this process can decide for itself.
  #
  # glibc opens a new malloc arena for roughly every core that contends for the
  # same one, and each arena maps memory of its own that is only ever released
  # back to the arenas, not to the kernel. A web server that had been up and
  # serving turns for 14 hours was measured at 388MB RSS with 317MB of it in 29
  # arenas on 12 cores.
  #
  # MALLOC_ARENA_MAX is read at the first allocation, so setting it from inside
  # a running Ruby changes nothing; the launcher passes it to the child so the
  # value is already there when glibc first looks.
  module LaunchEnv
    # Two arenas keep the per arena cost bounded while still giving a
    # multi-threaded server more than the single locked arena.
    MALLOC_ARENA_MAX = "2"

    # Defaults to merge into the environment handed to the child. A value the
    # operator already exported wins, because they may know something about
    # this machine that the default does not.
    def self.child_env(env = ENV)
      current = env["MALLOC_ARENA_MAX"].to_s
      return {} unless current.strip.empty?

      { "MALLOC_ARENA_MAX" => MALLOC_ARENA_MAX }
    end
  end
end
