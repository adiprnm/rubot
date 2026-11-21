# frozen_string_literal: true

module Rubot
  # Text shaping shared by more than one channel. Every function here is small,
  # free of state, and identical to the copy it replaced: the point is that a
  # channel never has to invent its own answer to "how long ago was this" or
  # "cut this line to fit", and that a change to how a duration reads lands in
  # one file instead of four.
  module Formatting
    module_function

    # How long a call waited, e.g. "4s" or "1m 5s". Only calls slow enough to
    # make the reader wonder get one, so the ordinary quick call stays a single
    # quiet line.
    def duration(seconds)
      total = seconds.to_i
      minutes, secs = total.divmod(60)
      return "#{secs}s" if minutes.zero?

      hours, minutes = minutes.divmod(60)
      return "#{minutes}m #{secs}s" if hours.zero?

      "#{hours}h #{minutes}m"
    end

    # The same idea while a call is still running, where a tenth of a second is
    # the difference between "0.4s" and "0s". Never shows hours: a sub agent
    # that runs that long has already been reported as stuck.
    def precise_duration(seconds)
      value = seconds.to_f
      return "#{value.round(1)}s" if value < 60

      minutes = (value / 60).floor
      rest = (value % 60).round
      rest.zero? ? "#{minutes}m" : "#{minutes}m #{rest}s"
    end

    # How long ago, in the units a reader actually uses. Absolute times would
    # have to assume a timezone; a difference between two instants does not.
    def age(epoch, now: Time.now)
      seconds = now.to_f - epoch.to_f
      return "baru saja" if seconds < 90
      return "#{(seconds / 60).round} mnt" if seconds < 3600
      return "#{(seconds / 3600).round} jam" if seconds < 86_400
      return "#{(seconds / 86_400).round} hr" if seconds < 2_592_000

      date = Time.at(epoch).utc.strftime("%d %b").sub(/\A0/, "")
      "#{date} lalu"
    end

    # Cut a line to what a notification can show without swallowing a word in
    # the middle of it.
    def shorten(text, limit)
      line = text.to_s.strip
      return line if line.length <= limit

      cut = line[0, limit - 1]
      cut = cut.sub(/\s+\S*\z/, "") if cut.include?(" ")
      "#{cut.rstrip}…"
    end

    # A hard cut, for ids, paths and labels that have no words to respect.
    def truncate(text, max_len)
      return text unless text && text.length > max_len

      "#{text[0, max_len]}…"
    end
  end
end
