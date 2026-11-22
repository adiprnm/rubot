# frozen_string_literal: true

require "json"
require_relative "push"

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
      def initialize(store:, vapid:, subject: Vapid::SUBJECT, urgency: Push::DEFAULT_URGENCY)
        @store = store
        @vapid = vapid
        @subject = subject
        # How hard the push service should work to reach a sleeping device.
        # `high` is the default because every notification here means "there is
        # something to read now"; an install that minds the buzz can say
        # `normal` in its web channel config and accept later delivery.
        @urgency = Push.normalize_urgency(urgency)
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
                                                  key: @vapid.key, subject: @subject,
                                                  urgency: @urgency)
          counts["status"] << code
          case status
          when :ok then counts["sent"] += 1
          when :gone
            # The browser will never accept this endpoint again — the app was
            # removed or the permission revoked. Asking a second time is a
            # message into a void.
            @store.drop_push_subscription(subscription["endpoint"])
            counts["gone"] += 1
          else
            counts["failed"] += 1
            # A device that says nothing is indistinguishable from a delivery
            # that never happened, so the reason is written down: the push
            # service's own code is the only evidence there is when "no
            # notification arrived" is the complaint.
            warn "[push] #{slug}: #{status} (#{code.inspect}) for #{endpoint_host(subscription)}"
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

      private

      # The push service, not the endpoint: the endpoint is a capability — it
      # is what lets anyone send to this device — and a log line is not the
      # place to keep one.
      def endpoint_host(subscription)
        URI.parse(subscription["endpoint"].to_s).host.to_s
      rescue URI::InvalidURIError
        "?"
      end

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
