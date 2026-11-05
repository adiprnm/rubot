# syntax=docker/dockerfile:1

# Ruby 4 is required: Rubot uses Ractor::Port for session actors.
FROM ruby:4.0.9-slim

# Match the host UID/GID so files written to the mounted ~/.rubot
# (sessions, MEMORY.md, cron jobs) stay owned by your local user.
ARG UID=1000
ARG GID=1000

RUN set -eux; \
    if ! getent group "${GID}" >/dev/null; then \
      groupadd --gid "${GID}" rubot; \
    fi; \
    if ! getent passwd "${UID}" >/dev/null; then \
      useradd --create-home --uid "${UID}" --gid "${GID}" --shell /bin/bash rubot; \
    fi; \
    mkdir -p /home/rubot/.rubot/workspace; \
    chown -R "${UID}:${GID}" /home/rubot

ENV LANG=C.UTF-8 \
    HOME=/home/rubot \
    RUBOT_CONFIG=/home/rubot/.rubot/config.yml \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_JOBS=4

# Node.js + Chromium power the Squadron "featured image" generator, which the
# shell tool calls as `node featured/generate.mjs`. Installed here because the
# agent cannot install packages on the fly (and PATH exports are blocked by the
# safety guard). A couple of font packages keep Chromium text rendering sane.
#
# ImageMagick is the `magick` command used by the brand/carousel skills to
# downsample 2x screenshots to their final size (`magick in@2x.png -resize ...`).
# ffmpeg is used by the carousel-video recipes to build reels from slides.
# Without these the agent renders @2x assets it cannot resize or encode, and
# fails with "magick: not found".
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        nodejs \
        chromium \
        imagemagick \
        ffmpeg \
        ca-certificates \
        fonts-dejavu-core \
        fonts-liberation2; \
    rm -rf /var/lib/apt/lists/*; \
    node --version; \
    chromium --version; \
    magick -version | head -1; \
    ffmpeg -version | head -1

WORKDIR /app

# Runtime gems only. webrick is required for Telegram webhook mode.
COPY Gemfile ./
RUN bundle install && rm -rf /usr/local/bundle/cache

COPY bin ./bin
COPY lib ./lib
COPY config ./config

RUN chmod +x bin/rubot && chown -R "${UID}:${GID}" /app

USER ${UID}:${GID}

# Default to the interactive REPL. Override the command for other modes:
#   docker compose run --rm rubot -C telegram
#   docker compose run --rm rubot -m "hello"
ENTRYPOINT ["ruby", "bin/rubot"]
CMD ["-C", "repl"]
