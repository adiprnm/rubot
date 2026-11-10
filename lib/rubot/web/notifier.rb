# frozen_string_literal: true

require "json"

module Rubot
  module Web
    # Telling the reader's devices that there is news, without a browser in the
    # way.
    #
    # The channel has a notifier of its own — it needs to answer "did that
    # reach Google?" for the test button — but the same job has to be possible
    # from the command line, from a cron job, or from an agent that just
    # finished something the reader asked to be told about. So the delivery
    # lives here, taking a store and a key, and every caller shares it.
    #
    # Nothing here decides *whether* something is worth announcing; that is the
    # caller's judgement (a fired job, a turn that outlived its reader).
    class Notifier
      def initialize(store:, vapid:, subject: Vapid::SUBJECT)
        @store = store
        @vapid = vapid
        @subject = subject
      end

      # Send now and report what happened. The counts are the whole answer the
      # test button needs: how many devices took it, how many said they are
      # gone, and the push service's own status codes for the ones that did not.
      def deliver(slug, title:, body:, url:, force: false)
        subscriptions = @store.push_subscriptions(slug)
        return empty_counts.merge("reason" => "no subscriptions") if subscriptions.empty?

        payload = JSON.generate(message(slug, title, body, url, force))
        counts = empty_counts
        subscriptions.each do |subscription|
          status, code = Push.deliver_with_status(subscription: subscription, payload: payload,
                                                  key: @vapid.key, subject: @subject)
          counts["status"] << code
          case status
          when :ok then counts["sent"] += 1
          when :gone
            # The browser will never accept this endpoint again — the app was
            # removed or the permission revoked. Asking a second time is a
            # message into a void.
            @store.drop_push_subscription(subscription["endpoint"])
            counts["gone"] += 1
          else counts["failed"] += 1
          end
        end
        counts
      end

      # The same delivery, off the caller's thread: a turn or a cron fire must
      # not wait on Apple's or Google's edge to finish.
      def notify(slug, title:, body:, url:, force: false)
        count = @store.push_subscriptions(slug).length
        return empty_counts.merge("reason" => "no subscriptions") if count.zero?

        Thread.new do
          deliver(slug, title: title, body: body, url: url, force: force)
        rescue StandardError => e
          warn "[push] #{e.class}: #{e.message}"
        end
        { "queued" => count }
      end

      # The conversation a notification should open when nobody named one: the
      # persona's newest, which is the one being written in.
      def newest_session(slug)
        row = @store.sidebar(limit: 20).find { |entry| entry[:id].to_s.start_with?("web_#{slug}") }
        row && row[:id]
      end

      private

      def empty_counts
        { "sent" => 0, "gone" => 0, "failed" => 0, "status" => [] }
      end

      def message(slug, title, body, url, force)
        message = { "title" => title, "body" => body.to_s, "url" => url, "tag" => "rubot-#{slug}" }
        # A notification that is *for* the person at the screen (the test
        # button, a requested "I am done") says so, or the worker would skip it
        # for announcing something already visible.
        message["force"] = true if force
        message
      end
    end
  end
end
