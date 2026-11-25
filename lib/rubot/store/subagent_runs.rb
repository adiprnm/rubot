# frozen_string_literal: true

module Rubot
  class Store
    # Audit rows for delegated runs, as the store sees them.
    #
    # A parent turn can end while a sub agent is still working, so the run has
    # to be recorded before the answer exists: started when it is handed off,
    # finished when it comes back, and read once by the parent that asked.
    #
    # Moved as it was, comments included. `reported_at` is the whole hand-over
    # protocol and the ordering of the two updates is what makes an answer
    # arrive exactly once.
    module SubagentRuns
      # Open a run when a delegation starts. INSERT OR IGNORE so a retried call
      # with the same run id cannot create a second audit row.
      def start_subagent_run(run_id:, parent_session:, agent_slug:, task: nil, model: nil,
                             started_at: Time.now.utc.iso8601)
        @db.execute(
          <<~SQL,
            INSERT OR IGNORE INTO subagent_runs(
              run_id, parent_session, agent_slug, task, model, status, started_at
            ) VALUES(?, ?, ?, ?, ?, 'running', ?)
          SQL
          [ text_id(run_id), text_id(parent_session), text_id(agent_slug), task, model, started_at ]
        )
        @db.changes.positive?
      end

      # Close a run. `sub_session` is filled in once the sub agent's session id is
      # known; `result` is what the run answered with, `error` why it failed. A
      # run that was never opened is a no-op rather than an error, so a channel
      # that audits optionally cannot break the turn.
      def finish_subagent_run(run_id:, status:, sub_session: nil, error: nil, result: nil,
                              finished_at: Time.now.utc.iso8601)
        @db.execute(
          <<~SQL,
            UPDATE subagent_runs
            SET status = ?, sub_session = ?, error = ?, result = ?, finished_at = ?
            WHERE run_id = ?
          SQL
          [ status.to_s, sub_session, error, result, finished_at, text_id(run_id) ]
        )
        @db.changes.positive?
      end

      # Answers of finished runs the parent has not been told about yet, oldest
      # first: a background run reports into a conversation that has moved on, so
      # the model reads them when it asks, and each one is handed over once.
      #
      # `newest_first` is for the automatic report the channel sends when a batch
      # ends: the answers that just landed are the news, so a backlog waiting
      # behind them must not push them to the next report.
      def pending_subagent_results(parent_session, limit: 20, newest_first: false)
        @db.execute(
          <<~SQL,
            SELECT run_id, agent_slug, task, result, started_at, finished_at
            FROM subagent_runs
            WHERE parent_session = ? AND status = 'done' AND reported_at IS NULL AND result IS NOT NULL
            ORDER BY started_at #{newest_first ? "DESC" : "ASC"}
            LIMIT ?
          SQL
          [ text_id(parent_session), limit.to_i ]
        ).map do |row|
          {
            run_id: row[0], agent_slug: row[1], task: row[2], result: row[3],
            started_at: row[4], finished_at: row[5]
          }
        end
      end

      # Mark answers as handed over. Called with the ids that were actually
      # returned, so a run that finished in between is not swallowed unread.
      def mark_subagent_results_reported(run_ids, at: Time.now.utc.iso8601)
        ids = Array(run_ids).map { |id| text_id(id) }.reject(&:empty?)
        return 0 if ids.empty?

        marks = ([ "?" ] * ids.size).join(", ")
        @db.execute(
          "UPDATE subagent_runs SET reported_at = ? WHERE run_id IN (#{marks})",
          [ at.to_s ] + ids
        )
        @db.changes
      end

      # Give answers back to the unread pile, for a report that could not be
      # delivered. Marked read and then lost is the one outcome a background run
      # cannot come back from: the model never saw the answer and the store will
      # not offer it again.
      def release_subagent_results(run_ids)
        ids = Array(run_ids).map { |id| text_id(id) }.reject(&:empty?)
        return 0 if ids.empty?

        marks = ([ "?" ] * ids.size).join(", ")
        @db.execute(
          "UPDATE subagent_runs SET reported_at = NULL WHERE run_id IN (#{marks})",
          ids
        )
        @db.changes
      end

      # Runs of one parent conversation, newest first. `limit: nil` reads all.
      def subagent_runs(parent_session, limit: 50)
        sql = +"SELECT run_id, parent_session, sub_session, agent_slug, task, model, " \
               "status, error, started_at, finished_at FROM subagent_runs WHERE parent_session = ? " \
               "ORDER BY started_at DESC"
        params = [ text_id(parent_session) ]
        if limit
          sql << " LIMIT ?"
          params << limit.to_i
        end
        @db.execute(sql, params).map do |row|
          {
            run_id: row[0], parent_session: row[1], sub_session: row[2], agent_slug: row[3],
            task: row[4], model: row[5], status: row[6], error: row[7],
            started_at: row[8], finished_at: row[9]
          }
        end
      end
    end
  end
end
