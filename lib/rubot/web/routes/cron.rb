# frozen_string_literal: true

module Rubot
  module Web
    module Routes
      # What a fired reminder becomes in the browser: a conversation written to,
      # a notification that reaches a phone with the app closed, and the words
      # that notification uses.
      #
      # Included into the channel, so it can open a turn in a session and reach
      # the notifier by their names.
      module Cron
        # A notification body is read on a lock screen: two or three lines, one
        # glance. The whole answer is one tap away, so what travels is the gist.
        TURN_NOTIFY_CHARS = 140
        # The bold line of a notification is the shortest thing on the screen, so
        # it gets the least room: a hook that does not fit is not a hook.
        NOTIFY_HOOK_CHARS = 60

        private

        def bind_cron_delivery(sid)
          cron = session_for(sid).tools.get("cron")
          return unless cron

          cron.delivery_context = {
            channel: "web",
            workspace: workspace_for_session(sid),
            # Which persona the reminder belongs to, so a fired job can open a
            # conversation there instead of falling back to the default one.
            slug: owner_slug(sid)
          }
        end

        def workspace_for_session(sid)
          rooted = @pool.workspace_for_session(sid) if actor_mode? && @pool.respond_to?(:workspace_for_session)
          rooted || @app_config&.workspace
        rescue StandardError
          @app_config&.workspace
        end

        # A fired job has no browser waiting on it, so it is delivered by
        # writing to a conversation: the page shows it the next time it asks for
        # the persona's sessions. A job that asked for its own conversation gets
        # a new session each run, which is how a daily practice prompt arrives as
        # a fresh chat instead of piling up in one.
        def handle_cron_fire(result)
          case result[:mode]
          when "agent_turn"
            deliver_cron_turn(result)
          when "deliver"
            # A "deliver" job has no turn to run: it is a message written for the
            # moment it fires. There is no session to open, so the notification
            # points at the persona's own conversation instead.
            slug = result[:slug].to_s
            slug = default_slug unless known_slug?(slug)
            notify_push(
              slug,
              title: persona_title(slug),
              body: result[:result][:deliver_message].to_s.strip.then { |text| text.empty? ? cron_note(result) : text },
              url: session_url(session_id(slug))
            )
          else
            warn "[web] cron fired (#{result[:mode]}) with nowhere to put it in the browser"
          end
        rescue StandardError => e
          warn "[web] cron delivery failed: #{e.class}: #{e.message}"
        end

        def deliver_cron_turn(result)
          slug = result[:slug].to_s
          slug = default_slug unless known_slug?(slug)

          sid = if result[:new_session]
            new_session_id(slug)
          else
            session_id(slug)
          end

          prepare_delivery(sid)
          session = session_for(sid)
          reply = session.process_cron(
            result[:result][:agent_message],
            fresh: result[:new_session] ? true : false
          )

          # A conversation the job opened has no user message to be named after,
          # so it takes the job's own description and the day it ran.
          if result[:new_session] && session.respond_to?(:set_session_title)
            session.set_session_title(cron_session_title(result))
          end

          # Whoever has the app open hears about it now, rather than on the next
          # reload — any persona's page, because the roster and the drawer's count
          # are the install's.
          broadcast_sessions

          # And whoever does not: a reminder is the whole point of firing while
          # the app is closed. Pages that are open are skipped by the worker
          # itself, so this cannot ring twice for the same news.
          #
          # A conversation the job just opened has already been given its first
          # line by the persona, and that line is the better invitation: the
          # job's description says what the job is ("Daily English speaking
          # practice"), while the opening says why to unlock the phone ("What's
          # one small win you had this week?"). So a new conversation announces
          # itself in its own words, and a reminder — which has no opening worth
          # quoting — keeps saying what it is.
          title, note = if result[:new_session]
            hook = cron_hook(slug, reply)
            [ hook, cron_note(result, reply: reply, spoken: hook) ]
          else
            [ persona_title(slug), cron_note(result) ]
          end

          notify_push(slug, title: title, body: note, url: session_url(sid))
        end

        # What a notification says about a fired job.
        #
        # With a reply to quote, it says whatever the persona asked — a question
        # is the one thing a reader can answer straight from the lock screen. A
        # reply with no question is quoted by its first line. Nothing to quote
        # leaves the description, which is the reader's own words for the job
        # ("minum air", "cek inbox") and more useful than a timestamp — and it is
        # sealed to the device, so a push service never reads it.
        def cron_note(result, reply: nil, spoken: nil)
          lines = cron_lines(reply).reject { |candidate| candidate == spoken }
          # A question is what a reader can answer straight from the lock screen,
          # so it is preferred over a line that only sets the scene.
          line = lines.find { |candidate| candidate.include?("?") } || lines.first
          return shorten(line, TURN_NOTIFY_CHARS) if line

          label = result[:description].to_s.gsub(/\s+/, " ").strip
          label.empty? ? "Sesi terjadwal sudah siap." : shorten(label, TURN_NOTIFY_CHARS)
        end

        # The bold line on the lock screen for a conversation that just began: the
        # first thing the persona said, which is the invitation itself.
        def cron_hook(slug, reply)
          line = cron_lines(reply).first
          line ? shorten(line, NOTIFY_HOOK_CHARS) : persona_title(slug)
        end

        # A reply is markdown written for a page — headings, bold, code spans and
        # blank lines between paragraphs. A notification is one glance at one
        # line, so the punctuation that only means something next to a stylesheet
        # is dropped and the lines are handed back in the order they were spoken.
        def cron_lines(reply)
          reply.to_s.split("\n").map do |line|
            line.strip
                .sub(/\A[#>*\-]+\s*/, "")
                .gsub(/\*\*|__|`/, "")
                .gsub(/\s+/, " ")
                .strip
          end.reject(&:empty?)
        end

        def cron_session_title(result)
          label = result[:description].to_s.strip
          label = "Scheduled session" if label.empty?
          "#{label} — #{Time.now.strftime('%Y-%m-%d')}"
        end
      end
    end
  end
end
