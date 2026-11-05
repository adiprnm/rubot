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
# safety guard). A couple of font packages keep text rendering sane.
#
# `chromium-headless-shell` instead of `chromium`: same engine and version, but
# it drops GTK/Adwaita/X11 toolkits. Every screen-render path here is headless
# (carousel render.sh, kanyaah render.js, featured generate.mjs), and both drive
# it either as a CLI (`--headless --screenshot`) or through puppeteer-core with
# `headless: "new"`. The two symlinks keep both spellings working, including
# scripts that look for an absolute `/usr/bin/chromium`.
#
# ImageMagick is the `magick` command used by the brand/carousel skills to
# downsample 2x screenshots to their final size (`magick in@2x.png -resize ...`).
#
# The errors "Failed to connect to the bus", "drmGetDevices2() has not found any
# devices" and "Floss manager service not available" on stderr are expected:
# there is no D-Bus, DRM device or Bluetooth in the container. Every caller
# redirects stderr, so they never reach the agent.
#
# Everything that follows must stay in this ONE RUN layer. Files deleted in a
# later RUN only disappear from the final filesystem view — the bytes stay in
# the earlier layer and the image does not shrink. That is why the GPU purge and
# the Vulkan-layer deletion are here instead of in their own step.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        nodejs \
        chromium-headless-shell \
        imagemagick \
        ca-certificates \
        xz-utils \
        fonts-dejavu-core \
        fonts-liberation2; \
    rm -rf /var/lib/apt/lists/*; \
    dpkg --purge --force-depends mesa-libgallium libllvm19 libz3-4; \
    rm -f /usr/lib/chromium/libVkLayer_khronos_validation.so; \
    ln -sf /usr/bin/chromium-headless-shell /usr/bin/chromium; \
    ln -sf /usr/bin/chromium-headless-shell /usr/bin/chromium-browser; \
    test ! -e /usr/lib/x86_64-linux-gnu/libLLVM.so.19.1; \
    test ! -e /usr/lib/chromium/libVkLayer_khronos_validation.so; \
    node --version; \
    chromium --version; \
    magick -version | head -1; \
    chromium --headless --disable-gpu --no-sandbox --dump-dom about:blank >/dev/null

# Every render here is a headless screenshot with `--disable-gpu`, so the GPU
# stack Debian pulls in for libgbm is dead weight: mesa-libgallium (41 MiB),
# its LLVM JIT backend (124 MiB) and libz3 (27 MiB) — ~190 MiB of driver code
# that is never loaded. Dropped above by the `dpkg --purge`; verified by
# comparing renders byte for byte (`sha256sum` identical) through both the CLI
# and puppeteer-core.
#
# Consequence: libgbm1 now has an unmet dependency, so do NOT run
# `apt-get -f install` / `apt-get autoremove` in this image — it would remove
# libgbm1 and then chromium-headless-shell. Add packages by rebuilding instead.
#
# libVkLayer_khronos_validation.so (23 MiB) is Vulkan's debug-only validation
# layer, loaded only when VK_INSTANCE_LAYERS asks for it.

# ffmpeg encodes the carousel-video reels. The static build replaces the
# Debian `ffmpeg` package: identical binaries to use, but no ~450 MiB of
# libav*/x265/aom/svt-av1 library packages, and no glibc or soname coupling to
# the base image. Downloaded with Ruby (no curl/wget in the image) and pinned by
# version + sha256 so a rebuild is reproducible.
ARG FFMPEG_VERSION=7.0.2
ARG FFMPEG_SHA256=abda8d77ce8309141f83ab8edf0596834087c52467f6badf376a6a2a4c87cf67

RUN set -eux; \
    tmp="$(mktemp -d)"; \
    ruby -rnet/http -ruri -e 'url=URI(ARGV[0]);dest=ARGV[1];Net::HTTP.start(url.host,url.port,use_ssl:url.scheme=="https"){|http|http.request(Net::HTTP::Get.new(url)){|res|raise "download failed: #{res.code} #{res.message}" unless res.is_a?(Net::HTTPSuccess);File.open(dest,"wb"){|f|res.read_body{|c|f.write(c)}}}}' \
        "https://johnvansickle.com/ffmpeg/releases/ffmpeg-${FFMPEG_VERSION}-amd64-static.tar.xz" "$tmp/ffmpeg.tar.xz"; \
    echo "${FFMPEG_SHA256}  $tmp/ffmpeg.tar.xz" | sha256sum -c -; \
    tar -xJf "$tmp/ffmpeg.tar.xz" -C "$tmp" --strip-components=1; \
    install -m 0755 "$tmp/ffmpeg" /usr/local/bin/ffmpeg; \
    install -m 0755 "$tmp/ffprobe" /usr/local/bin/ffprobe; \
    rm -rf "$tmp"; \
    ffmpeg -version | head -1; \
    ffprobe -version | head -1

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
