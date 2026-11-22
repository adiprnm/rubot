# frozen_string_literal: true

module Rubot
  class Session
    # Where a session is written, and what of it is written.
    #
    # Two stores live behind one interface: the SQLite archive (the store, when
    # a StoreClient is present) and the JSON file (an export, one per session).
    # Both are restored through one path: the archive returns its metadata blob
    # under the same keys the JSON file used, so #load! reads either without
    # asking which one answered.
    #
    # The file's bytes are a contract — /resume, the store indexer and older
    # builds all read them — and test/test_session_export_format.rb pins them.
    module Archive
      def file_path
        return nil unless @sessions_dir
        File.join(@sessions_dir, "#{@id}.json")
      end

      # Persist session to disk. Uses an exclusive file lock so a session
      # file is never partially written even if another process/Ractor
      # touches it at the same time.
      #
      # A session that has no content yet is not written, and an existing file
      # for it is removed. That keeps a launch that the user closes before
      # typing anything out of the sessions directory (and out of /resume).
      def save!
        return save_to_archive! if @archive
        return unless file_path

        unless persistable?
          # Only a file this copy wrote is this copy's to remove. Another copy
          # of the same session can exist (the prompt pinning path builds one
          # before it loads anything), and that copy arriving here must not take
          # a transcript, and the name on it, off the disk.
          FileUtils.rm_f(file_path) if @wrote_file
          return
        end

        FileUtils.mkdir_p(File.dirname(file_path))
        data = {
          "id" => @id,
          "created_at" => @messages.first&.fetch("timestamp", Time.now.iso8601),
          "updated_at" => Time.now.iso8601,
          "messages" => @messages
        }
        data["cwd"] = @cwd if @cwd
        data["task"] = @task if @task
        # More than one copy of a session can be in flight (the turn's, the
        # namer's, the one that pins a system prompt), and a copy loaded before
        # the namer wrote a title holds nothing for that field. The archive
        # refuses to let an empty title overwrite a real one (see
        # Store#upsert_session); the export keeps the same rule instead of
        # erasing a name it never saw.
        title = @title.to_s.strip.empty? ? (@title_known ? nil : title_on_disk) : @title
        data["title"] = title unless title.to_s.strip.empty?
        data["summary"] = @summary if @summary
        data["forced_skill"] = @forced_skill if @forced_skill
        data["model_override"] = @model_override if @model_override
        data["model_preset"] = @model_preset if @model_preset
        data["thinking_level"] = @thinking_level if @thinking_level
        data["usage"] = @usage.to_h
        data["last_usage"] = @last_usage.to_h
        data["cost"] = @cost if @cost
        data["cost_partial"] = true if @cost_partial
        data["last_usage_watermark"] = @last_usage_watermark if @last_usage_watermark
        data["cache_history"] = @cache_history if @cache_history && !@cache_history.empty?
        data["cache_records"] = @cache_records if @cache_records && !@cache_records.empty?
        data["compaction_events"] = @compaction_events if @compaction_events && !@compaction_events.empty?
        data["system_prompt"] = @system_prompt if @system_prompt
        data["system_prompt_epoch"] = @system_prompt_epoch if @system_prompt_epoch
        data["memory_backlog"] = @memory_backlog if @memory_backlog && !@memory_backlog.empty?
        data["system_additions"] = @system_additions if @system_additions && !@system_additions.empty?
        data["system_patch"] = @system_patch if @system_patch

        # Generate before opening the file: JSON.pretty_generate can raise (e.g.
        # invalid UTF-8), and truncating first would leave an empty session file.
        payload = JSON.pretty_generate(self.class.normalize_utf8(data))

        File.open(file_path, File::WRONLY | File::CREAT, 0o644) do |file|
          file.flock(File::LOCK_EX)
          file.truncate(0)
          file.write(payload)
          file.flush
          file.flock(File::LOCK_UN)
        end
        @wrote_file = true
      end

      private

      # The title already on the file, for a copy that never held one. Reads
      # before the file is truncated, and only parses when the text says a title
      # is in there at all, so an unnamed session that saves often pays a read
      # and nothing else.
      #
      # The read takes the shared lock the writer takes exclusively: another
      # copy may be rewriting this very file, and a half-written read would look
      # like "no title" and cost the name.
      def title_on_disk
        return @title_on_disk if @title_on_disk

        return nil unless file_path && File.exist?(file_path)

        content = File.open(file_path, "r") do |file|
          file.flock(File::LOCK_SH)
          file.read
        ensure
          file.flock(File::LOCK_UN) if file
        end
        return nil unless content.include?(%("title"))

        parsed = JSON.parse(content)
        @title_on_disk = parsed.is_a?(Hash) ? parsed["title"] : nil
      rescue StandardError
        nil
      end

      # Write only what is new. The old file path rewrote the whole transcript on
      # every save — up to 3.7 MB per turn on this repo's sessions — and the JSON
      # file is now an export rather than the store.
      #
      # Nothing here touches @messages, so the payload the model is sent stays
      # identical to what it was before the save: the prompt cache is not affected
      # by a turn being persisted.
      def save_to_archive!
        return false unless persistable?

        pending = @messages[@archived..] || []
        if pending.any?
          @archive.append(@id, pending, start_index: @archive_offset + @archived)
          @archived += pending.size
        end
        @archive.save_meta(
          @id,
          meta: archive_meta,
          messages_start: @archive_offset,
          title: @title,
          cwd: @cwd,
          created_at: @messages.first&.fetch("timestamp", nil)
        )
        true
      end

      # The same fields the JSON file carried. Keys match, so load! restores from
      # either source through one path; nil means "not set", not "unset it".
      def archive_meta
        {
          "summary" => @summary,
          "task" => @task,
          "forced_skill" => @forced_skill,
          "model_override" => @model_override,
          "model_preset" => @model_preset,
          "thinking_level" => @thinking_level,
          "usage" => @usage.to_h,
          "last_usage" => @last_usage.to_h,
          "cost" => @cost,
          "cost_partial" => @cost_partial,
          "last_usage_watermark" => @last_usage_watermark,
          "cache_history" => @cache_history,
          "compaction_events" => @compaction_events,
          # The pin: losing either of these rebuilds the system prompt, and a
          # rebuilt prompt at the front of the request is a cold cache.
          "system_prompt" => @system_prompt,
          "system_prompt_epoch" => @system_prompt_epoch,
          "memory_backlog" => @memory_backlog,
          "system_additions" => @system_additions,
          "system_patch" => @system_patch
        }.compact
      end

      # A freshly created session has nothing worth a file yet. Messages are the
      # obvious content; summary, usage and the memory backlog are kept too, so
      # state written before the first message (or by tests/tools) survives.
      def persistable?
        return true unless @messages.empty?
        return true if @summary && !@summary.strip.empty?
        return true if @forced_skill || @model_override || @model_preset || @thinking_level
        return true if @usage.requests.positive?
        return true if @last_usage.requests.positive?
        return true if @memory_backlog && !@memory_backlog.empty?

        false
      end

      def load!
        data = @archive ? archive_state : file_state
        return unless data

        @messages = self.class.normalize_utf8(data["messages"] || [])
        # Everything loaded is already in the archive; only what is appended
        # afterwards needs writing.
        @archived = @messages.size if @archive
        @cwd = data["cwd"].to_s.strip.empty? ? nil : data["cwd"].to_s if data.key?("cwd")
        @task = data["task"] if data["task"]
        # Sessions written before the task field existed: recover the first user
        # message if the transcript still starts with one.
        if @task.nil? && @messages.first && @messages.first["role"] == "user"
          @task = @messages.first["content"].to_s.strip
        end
        @summary = data["summary"] if data["summary"]
        @title = data["title"] if data["title"]
        @title_known = true unless data["title"].to_s.strip.empty?
        @forced_skill = data["forced_skill"] if data["forced_skill"]
        @model_override = data["model_override"] if data["model_override"]
        @model_preset = data["model_preset"] if data["model_preset"]
        @thinking_level = data["thinking_level"] if data["thinking_level"]
        @usage = Usage.from_h(data["usage"])
        @last_usage = Usage.from_h(data["last_usage"])
        @cost = load_cost(data["cost"])
        @cost_partial = data["cost_partial"] == true
        @last_usage_watermark = data["last_usage_watermark"].is_a?(Integer) ? data["last_usage_watermark"] : nil
        @cache_history = Array(data["cache_history"]).map(&:to_f).last(CACHE_HISTORY_LIMIT)
        @cache_records = Array(data["cache_records"])
          .select { |record| record.is_a?(Hash) }
          .last(CACHE_RECORDS_LIMIT)
        @compaction_events = Array(data["compaction_events"])
          .select { |event| event.is_a?(Hash) }
          .last(COMPACTION_EVENTS_LIMIT)
        @system_prompt = data["system_prompt"].to_s.empty? ? nil : data["system_prompt"].to_s
        @system_prompt_epoch = data["system_prompt_epoch"].is_a?(Hash) ? data["system_prompt_epoch"] : nil
        @memory_backlog = Array(data["memory_backlog"]).map(&:to_s)
        @system_additions = Array(data["system_additions"]).map(&:to_s)
        @system_patch = data["system_patch"].to_s.empty? ? nil : data["system_patch"].to_s
      end

      # The session state as the archive holds it: the messages it returned (which
      # already start at `messages_start`) plus the metadata blob under the same
      # keys the JSON file used, so one restore path serves both.
      def archive_state
        loaded = @archive.load(@id)
        return nil unless loaded

        @archive_offset = loaded[:start].to_i
        (loaded[:meta] || {}).merge(
          "messages" => loaded[:messages] || [],
          # The records live in their own table, not in the meta blob: they are
          # written per request and pruned, which a blob rewritten on every save
          # would make expensive and a race.
          "cache_records" => @archive.cache_records(@id, limit: CACHE_RECORDS_LIMIT)
        )
      end

      def file_state
        return nil unless file_path && File.exist?(file_path)

        raw = File.read(file_path)
        return nil if raw.strip.empty?

        JSON.parse(raw)
      rescue JSON::ParserError => e
        # A truncated/corrupt session must not take the bot down: start fresh.
        warn "[session] ignoring unreadable session #{file_path}: #{e.message}"
        nil
      end
    end
  end
end
