# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 4.0.0"

# Optional: only needed for the Telegram webhook server.
# WEBrick is no longer bundled with Ruby 4.
gem "webrick", "~> 1.8"

group :development, :test do
  gem "minitest", "~> 5.0"
  gem "rake"
end

group :development do
  gem "rubocop", require: false
  gem "rubocop-rails-omakase", require: false
end
