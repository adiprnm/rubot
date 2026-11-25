# frozen_string_literal: true

require "time"

require_relative "../tool"
require_relative "../formatting"
require_relative "../loop_store"
require_relative "../loop_worktree"

module Rubot
  module Tools
    # A loop is a goal an agent works at over many iterations, each one in a
    # worktree of its own. Like the cron tool this is a thin adapter: the channel
    # owns what actually iterates and injects it as `loop_runner`, so a loop can be
    # created and read with no agent behind it. The store is built per call,
    # because the registry is shared by every session in a Ractor.
    class Loop < Tool
      OPERATIONS = %w[start status list pause resume stop undo].freeze
      GOAL_CHARS = 60 # a listing is one line per loop
      LOG_LINES = 5   # the tail of the log is the state; the rest is not worth the tokens
      # The store owns the numbers: a loop created without a cap and a call that
      # falls back to this one must record the same three, and a loop created
      # without a budget must get the same twelve million. Two places stating
      # one fact is how the old 500,000 became a budget smaller than the
      # iteration it was meant to brake.
      DEFAULT_MAX_ITERATIONS = LoopStore::State::DEFAULT_MAX_ITERATIONS
      DEFAULT_MAX_TOKENS = LoopStore::State::DEFAULT_MAX_TOKENS

      # Arguments the channel may stamp as fallbacks (a repo, a cap), and the handle.
      attr_accessor :defaults, :loop_runner
      # The agent this tool runs inside, stamped by the turn (see
      # Agent::ToolWiring#inject_tool_delegate). In actor mode it is the only
      # way out: the channel holds a proxy here, so no runner can be attached,
      # and the agent is what passes the request to the channel instead.
      attr_writer :agent
      # The root the state files live under, stamped by a channel that knows it:
      # the registry builds one tool for every session in a Ractor.
      attr_writer :workspace, :store_root

      def initialize(store_root: nil, workspace: nil)
        @store_root = store_root
        @workspace = workspace
        @defaults = {}
        @loop_runner = nil
      end

      def name = "loop"

      def description
        "Work a goal through repeated iterations until it can be checked as done. " \
          "Every loop gets a git worktree and a branch of its own, and nothing is pushed.\n\n" \
          "Operations: start (needs goal, done_criteria and repo, an existing directory), " \
          "operations: start (needs goal, done_criteria and repo, an existing directory), " \
          "status (the facts plus the last 5 log entries), list, pause, resume, stop, " \
          "undo (drop the last committed iteration of a paused or stalled loop)."
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "operation" => { "type" => "string", "enum" => OPERATIONS, "description" => "Loop operation" },
            "id" => { "type" => "string", "description" => "Loop id (status, pause, resume, stop)" },
            "goal" => { "type" => "string", "description" => "The outcome the loop works toward (start)" },
            "done_criteria" => { "type" => "string", "description" => "How a verifier tells the goal is reached (start)" },
            "repo" => { "type" => "string", "description" => "Path of the git repository the loop works in (start)" },
            "max_iterations" => {
              "type" => "integer",
              "description" => "Iteration cap (start, default #{DEFAULT_MAX_ITERATIONS}); " \
                               "resume raises it above the iterations already spent"
            },
            "max_tokens" => {
              "type" => "integer",
              "description" => "Token budget for the whole loop (start, default #{DEFAULT_MAX_TOKENS}); " \
                               "the run stops a turn that spends it rather than waiting for an iteration to end. " \
                               "resume raises it, and that is the only way a loop that spent its budget runs again"
            }
          },
          "required" => [ "operation" ]
        }
      end

      # Every answer is a plain string the model reads: "OK: ..." or "ERROR: ...".
      # Nothing here raises, because that would cost the turn its chance to retry
      # with better arguments.
      def execute(arguments)
        args = with_defaults(arguments)
        operation = text(args["operation"])
        return unknown_operation(operation) unless OPERATIONS.include?(operation)

        store = build_store
        case operation
        when "start"  then start_loop(store, args)
        when "list"   then list_loops(store)
        when "status" then status_of(store, args)
        when "pause"  then halt(store, args, "pause")
        when "resume" then resume(store, args)
        when "stop"   then halt(store, args, "stop")
        when "undo"   then undo_iteration(store, args)
        end
      rescue StandardError => e
        "ERROR: #{e.message}"
      end

      private

      def start_loop(store, args)
        goal, criteria, repo = %w[goal done_criteria repo].map { |key| text(args[key]) }
        return "ERROR: start needs a goal: the outcome the loop works toward" if goal.empty?
        return "ERROR: start needs done_criteria: how a verifier tells the goal is reached" if criteria.empty?
        return "ERROR: start needs a repo: the git repository the loop works in" if repo.empty?

        path = File.expand_path(repo)
        return "ERROR: repo is not an existing directory: #{path}" unless File.directory?(path)

        budget, refusal = max_tokens_for_start(args)
        return refusal if refusal

        state = store.create(goal: goal, done_criteria: criteria, repo: path,
                             max_iterations: max_iterations(args), max_tokens: budget)
        if @loop_runner
          @loop_runner.start(state.id)
          return "OK: loop #{state.id} started in a worktree of its own: #{truncated(state.goal)} " \
                 "#{allowance(state)}"
        end

        handed = request_from_agent(:start, state.id)
        return "#{handed} #{allowance(state)}" if handed

        "OK: loop #{state.id} created, but no runner is attached to this channel, so it will not iterate. " \
          "#{allowance(state)}"
      end

      # What a start has just allowed, said out loud. The budget a loop gets
      # without asking is twelve million tokens, which is a number nobody can
      # guess: a start that whispers it leaves a reader to discover the bill.
      def allowance(state)
        "Budget: #{state.max_tokens} tokens, up to #{state.max_iterations} iterations."
      end

      def list_loops(store)
        states = store.ids.filter_map { |id| store.load(id) }
        return "No loops." if states.empty?

        states.map do |state|
          "#{state.id} #{state.status} it=#{state.iterations}/#{state.max_iterations} " \
            "tok=#{state.tokens} #{truncated(state.goal)}"
        end.join("\n")
      end

      def status_of(store, args)
        state, error = state_for(store, args)
        return error if error

        "#{frontmatter(state)}\n#{log_tail(state.log)}"
      end

      def frontmatter(state)
        [
          [ "id", state.id ], [ "status", state.status ], [ "goal", one_line(state.goal) ],
          [ "done_criteria", one_line(state.done_criteria) ], [ "repo", state.repo ],
          [ "worktree", state.worktree || "-" ], [ "branch", state.branch || "-" ],
          [ "iterations", "#{state.iterations}/#{state.max_iterations}" ],
          [ "tokens", "#{state.tokens}/#{state.max_tokens}" ],
          [ "created_at", stamp(state.created_at) ], [ "updated_at", stamp(state.updated_at) ]
        ].map { |key, value| "#{key}: #{value}" }.join("\n")
      end

      # Newest first, like the file, and capped: iteration 30 must not cost what
      # iteration 2 did.
      def log_tail(log)
        entries = log.first(LOG_LINES)
        return "log: (empty)" if entries.empty?

        ([ "log (newest first):" ] + entries.map { |entry| "  #{stamp(entry.at)} #{entry.text}" }).join("\n")
      end

      # Pause and stop are the same write: the loop stops iterating and stays resumable.
      def halt(store, args, operation)
        state, error = state_for(store, args)
        return error if error

        verb = operation == "stop" ? "stopped" : "paused"
        return "OK: loop #{state.id} is done; it was not #{verb}" if state.status == "done"

        store.update(state.id) { |loop| loop.status = "paused" }
        if @loop_runner
          # The runner is the one that knows whether the write landed and what is
          # still being paid for, so its sentence is the one the reader gets. A
          # runner that answers with something other than a string still leaves
          # the model with a plain string, which is what a tool owes it.
          answer = @loop_runner.abort(state.id)
          return answer.is_a?(String) ? answer : "OK: loop #{state.id} #{verb}; the runner was told to abort"
        end

        handed = request_from_agent(:abort, state.id)
        return handed if handed

        "OK: loop #{state.id} #{verb}; no runner is attached to this channel"
      end

      # A loop that stopped at its cap is paused, so a resume that could not move
      # the cap could never get it going again: the run checks the cap before it
      # spends anything and would stop on the same number every time. This is
      # where the user already is when that happens, so this is where the cap is
      # raised -- and it reaches the file, because the run reads it there.
      #
      # The budget is the same fact with the same failure: a spent loop stops at
      # the run's own boundary before it spends a token, so a resume that does
      # not raise `max_tokens` buys nothing. It is refused here, which makes
      # raising the budget the one road back for a loop that ran out.
      def resume(store, args)
        state, error = state_for(store, args)
        return error if error
        return "ERROR: loop #{state.id} is done; start a new loop if the goal moved" if state.status == "done"

        cap, refusal = cap_for_resume(state, args)
        return refusal if refusal
        budget, refusal = budget_for_resume(state, args)
        return refusal if refusal

        if state.status == "active"
          return "OK: loop #{state.id} is already active and iterating" if cap.nil? && budget.nil?

          # A loop already iterating is not started a second time -- two runs on
          # one worktree share an index and an iteration number -- but its cap is
          # a fact in the file, and raising it is the one useful thing to do here.
          store.update(state.id) do |loop|
            loop.max_iterations = cap if cap
            loop.max_tokens = budget if budget
          end
          return "OK: loop #{state.id} is already active; #{raised_note(cap, budget)}"
        end

        # One write, before the runner is asked to continue: the run reads the
        # cap and the budget from the file, so a number written afterwards is one
        # it never saw.
        store.update(state.id) do |loop|
          loop.max_iterations = cap if cap
          loop.max_tokens = budget if budget
          loop.status = "active"
        end
        note = raised_note(cap, budget)
        if @loop_runner
          @loop_runner.resume(state.id)
          return "OK: loop #{state.id} resumed; #{note}; the runner was asked to continue" unless note.empty?

          return "OK: loop #{state.id} resumed; the runner was asked to continue"
        end

        handed = request_from_agent(:resume, state.id)
        return [ handed, note ].reject(&:empty?).join("; ") if handed

        "OK: loop #{state.id} resumed; no runner is attached to this channel"
      end

      # What a resume changed, in the reader's words: the two facts that stop a
      # loop and are the only ones a resume may move. Empty when it moved none.
      def raised_note(cap, budget)
        facts = []
        facts << "its cap is now #{cap}" if cap
        facts << "its budget is now #{budget} tokens" if budget
        facts.join(" and ")
      end

      # The cap a resume asks for, and the refusal when it leaves the loop with
      # nowhere to go: the run stops on a cap at or below the iterations already
      # spent, so a resume writing one would be a resume that cannot continue.
      # nil is "no cap was asked for", which is not a cap of zero.
      def cap_for_resume(state, args)
        raw = text(args["max_iterations"])
        return [ nil, nil ] if raw.empty?

        cap = Integer(raw, exception: false)
        return [ nil, "ERROR: max_iterations must be a whole number; got #{raw.inspect}" ] if cap.nil?

        spent = state.iterations.to_i
        if cap <= spent
          return [ nil, "ERROR: loop #{state.id} has already run #{spent} iterations; " \
                        "max_iterations must be above #{spent} to resume it, and #{cap} is not" ]
        end

        [ cap, nil ]
      end

      # The budget a resume asks for, and the two refusals around it. A budget a
      # loop has already spent is the one thing a resume cannot walk away from:
      # the run stops on the file's own numbers before it spends anything, so
      # waking it again and again buys nothing and announces the same stop every
      # time. Raising the budget is the road back, which is why the resume that
      # names none is refused instead of writing a status nobody can act on.
      def budget_for_resume(state, args)
        raw = text(args["max_tokens"])
        if raw.empty?
          spent = state.tokens.to_i
          return [ nil, nil ] if spent < state.max_tokens.to_i

          return [ nil, "ERROR: loop #{state.id} has spent #{spent} of #{state.max_tokens} tokens; " \
                        "raise max_tokens above #{spent} to resume it" ]
        end

        budget = Integer(raw, exception: false)
        if budget.nil? || budget <= 0
          return [ nil, "ERROR: max_tokens must be a whole number of tokens above zero; got #{raw.inspect}" ]
        end

        spent = state.tokens.to_i
        if budget <= spent
          return [ nil, "ERROR: loop #{state.id} has spent #{spent} tokens; max_tokens must be above " \
                        "#{spent} to resume it, and #{budget} is not" ]
        end

        [ budget, nil ]
      end

      # Drop the last committed iteration: the worktree goes back one commit on
      # the branch it keeps, which is what makes a bad iteration cheap to
      # abandon. Two statuses are refused. `active` because a reset under a live
      # iteration is how a half-written commit is lost, and `done` because its
      # worktree was already removed. Iterations and tokens are left exactly as
      # they are: the budget records what was spent, and rewinding it would lie
      # about money already paid to a provider.
      def undo_iteration(store, args)
        state, error = state_for(store, args)
        return error if error
        return "ERROR: loop #{state.id} is done; its worktree is gone, so there is nothing to undo" if state.status == "done"
        return "ERROR: loop #{state.id} is active; pause it first, or a running iteration loses its commit" if state.status == "active"

        path = text(state.worktree)
        return "ERROR: loop #{state.id} has no worktree recorded" if path.empty?
        return "ERROR: loop #{state.id} has no worktree on disk: #{path}" unless File.directory?(path)

        # The recorded path is the one truth: deriving the root from it means a
        # loop made under another worktree root can still be undone.
        worktree = LoopWorktree.new(root: File.dirname(path), repo: state.repo)
        unless worktree.reset_last(state.id)
          return "ERROR: loop #{state.id} has nothing to undo: the branch has a single commit"
        end

        store.append_log(state.id, "iteration undone: the worktree went back one commit")
        "OK: loop #{state.id} went back one commit; iterations and tokens are unchanged"
      rescue LoopWorktree::Error => e
        "ERROR: could not undo loop #{text(args['id'])}: #{e.message}"
      end

      # Ask the agent to hand this operation to the channel, for a tool that
      # holds no runner of its own. In actor mode the channel can only give it a
      # proxy on this side, and a thread, a session pool and a lambda do not
      # cross a Ractor, so the agent is the only way out. nil back means no
      # channel asked for loops at all, and the caller owes its honest "no
      # runner" sentence -- which is what it said before anyone asked.
      def request_from_agent(op, id)
        return nil unless @agent

        answer = @agent.request_loop(op: op, id: id)
        return nil unless answer.is_a?(String)
        # The agent speaks to the model in a sentence; this tool owes every call
        # the same "OK:" / "ERROR:" shape, and the channel's UI reads the error
        # mark from it.
        return answer if answer.start_with?("OK:", "ERROR:")

        "OK: #{answer}"
      end

      def state_for(store, args)
        id = text(args["id"])
        return [ nil, "ERROR: this operation needs an id; list the loops to find it" ] if id.empty?

        state = store.load(id)
        return [ nil, "ERROR: no loop '#{id}'" ] if state.nil?

        [ state, nil ]
      end

      def unknown_operation(operation) = "ERROR: unknown operation #{operation.inspect}. Valid operations: #{OPERATIONS.join(', ')}."

      # One store per call, rooted beside the workspace unless the channel named an
      # install root, which is what the cron tool does for its jobs.
      def build_store
        base = @store_root || @workspace
        raise ArgumentError, "no workspace is configured for the loop tool" if base.to_s.strip.empty?

        LoopStore.new(dir: File.join(base.to_s, "loops"))
      end

      # Fallbacks stamped by the channel, filling only what the call left blank.
      def with_defaults(arguments)
        args = arguments.is_a?(Hash) ? arguments.dup : {}
        @defaults.to_h { |key, value| [ key.to_s, value ] }.each do |name, value|
          args[name] = value if args[name].to_s.strip.empty?
        end
        args
      end

      def max_iterations(args) = args["max_iterations"].to_i.positive? ? args["max_iterations"].to_i : DEFAULT_MAX_ITERATIONS

      # The budget a start names, nil for the store's own default. Refused rather
      # than coerced: "0", "12.5" and "a lot" are numbers somebody meant
      # something else by, and a loop created with a budget of zero stops before
      # its first iteration and reads as a bug nobody can trace. The message says
      # what was wrong with the value, because the caller can only retry what it
      # can see.
      def max_tokens_for_start(args)
        raw = text(args["max_tokens"])
        return [ nil, nil ] if raw.empty?

        budget = Integer(raw, exception: false)
        return [ nil, "ERROR: max_tokens must be a whole number of tokens above zero; got #{raw.inspect}" ] if budget.nil? || budget <= 0

        [ budget, nil ]
      end

      def text(value) = value.to_s.strip
      def one_line(value) = value.to_s.gsub(/\s+/, " ").strip
      def stamp(time) = time.nil? ? "-" : time.to_time.utc.iso8601
      def truncated(value) = Formatting.truncate(one_line(value), GOAL_CHARS)
    end
  end
end
