# frozen_string_literal: true

require "test_helper"
require "rubot"
require_relative "support/web_channel_support"

module Rubot
  module Web
    # The way in and the files served with it: the gate, the static assets and the installed app.
    class TestWebAssets < Minitest::Test
      include WebChannelSupport

      # --- the way in ------------------------------------------------------

      # A request from a browser asking for a page: what the gate answers.

      # Arriving without a token used to answer "token required" as plain text,
      # which left the reader nothing to act on: the token lived in the URL, so
      # a bookmark or a typed address was a dead end. The field is the way in.
      def test_a_page_without_a_token_asks_for_one_in_a_field
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })
        res = FakeResponse.new

        channel.send(:dispatch, gate_request("/s/web_kanyaah"), res)

        assert_equal 403, res.status
        assert_includes res.body, %(action="/unlock")
        assert_includes res.body, %(name="token")
        assert_includes res.body, %(type="password")
        refute_includes res.body, "token required"
      end

      # The token is not carried into the next URL: asking for it here is what
      # lets the address bar stop holding it, so where the reader was going is
      # kept without the one parameter the form is about.
      def test_the_form_carries_where_the_reader_was_going_without_the_token
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })
        res = FakeResponse.new

        channel.send(:dispatch, gate_request("/s/web_kanyaah", query_string: "token=nope&at=41"), res)

        assert_includes res.body, %(name="next" value="/s/web_kanyaah?at=41")
      end

      # htmx swaps a fragment into a page that is already open, and an SSE
      # client has nowhere to show a card: those keep the plain refusal rather
      # than being handed a document to paste somewhere.
      def test_a_fragment_or_a_stream_is_still_refused_plainly
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })

        htmx = FakeResponse.new
        channel.send(:dispatch, gate_request("/s/web_kanyaah/recent", htmx: true), htmx)
        assert_equal 403, htmx.status
        assert_equal "token required", htmx.body

        stream = FakeResponse.new
        channel.send(:dispatch, gate_request("/events", accept: "text/event-stream"), stream)
        assert_equal "token required", stream.body
      end

      def test_the_right_token_writes_the_cookie_and_opens_the_page_that_was_asked_for
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })
        res = FakeResponse.new

        channel.send(:dispatch,
                     gate_request("/unlock", method: "POST", query_string: "token=t0k&next=%2Fs%2Fweb_kanyaah"),
                     res)

        assert_equal 303, res.status
        assert_equal "/s/web_kanyaah", res.headers["Location"]
        assert_equal "rubot_token=t0k; Path=/; HttpOnly; SameSite=Lax", res.headers["Set-Cookie"]
        refute_includes res.headers["Location"].to_s, "token",
                        "the cookie is set: the URL no longer has to carry it"
      end

      def test_a_wrong_token_leaves_the_reader_at_the_field
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })
        res = FakeResponse.new

        channel.send(:dispatch, gate_request("/unlock", method: "POST", query_string: "token=nope"), res)

        assert_equal 403, res.status
        assert_includes res.body, Rubot::I18n.t("web.gate.token_mismatch")
        assert_nil res.headers["Set-Cookie"], "a wrong token writes no cookie"
      end

      # `next` is a path this app wrote into the form. An absolute URL typed in
      # by hand would otherwise make the gate an open redirect.
      def test_the_next_page_must_be_a_path_this_app_chose
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })

        [ "https://evil.example/x", "//evil.example/x" ].each do |bad|
          res = FakeResponse.new
          channel.send(:dispatch,
                       gate_request("/unlock", method: "POST",
                                               query_string: URI.encode_www_form("token" => "t0k", "next" => bad)),
                       res)

          assert_equal "/", res.headers["Location"], "#{bad.inspect} is not a path this app wrote"
        end
      end

      # --- assets ---------------------------------------------------------

      # --- installed app --------------------------------------------------

      # A phone installs what the manifest describes, so it has to name the app,
      # open at the doorway rather than at one conversation, and run without a
      # browser frame.
      def test_the_manifest_describes_an_installed_app
        manifest = JSON.parse(File.read(File.expand_path("../lib/rubot/web/assets/manifest.webmanifest", __dir__)))

        assert_equal "rubot", manifest["short_name"]
        assert_equal "standalone", manifest["display"]
        assert_equal "/", manifest["start_url"], "the doorway, not one session id"
        assert_equal "/", manifest["scope"]
        assert_equal "#2b332f", manifest["theme_color"]

        sizes = manifest["icons"].map { |icon| icon["sizes"] }
        assert_includes sizes, "192x192"
        assert_includes sizes, "512x512"
        assert_includes manifest["icons"].map { |icon| icon["purpose"] }, "maskable",
                        "Android crops a square icon, and the glyph has to survive it"
      end

      # Every icon the manifest promises has to exist, or the install offers the
      # app and then shows a blank square.
      def test_every_icon_the_manifest_names_is_on_disk
        assets = File.expand_path("../lib/rubot/web/assets", __dir__)
        manifest = JSON.parse(File.read(File.join(assets, "manifest.webmanifest")))

        manifest["icons"].each do |icon|
          name = File.basename(icon["src"])
          path = File.join(assets, name)

          assert File.file?(path), "#{name} is named in the manifest but missing"
          assert_equal "PNG", File.binread(path, 8)[1, 3], "#{name} has to be a real PNG"
        end
        assert File.file?(File.join(assets, "apple-touch-icon.png")),
               "iOS reads its own icon, not the manifest's"
      end

      # The page has to point at all of it: without the manifest link and the
      # Apple metas a phone offers a bookmark instead of an app.
      def test_the_page_points_at_the_installed_app
        html = View.render("layout", title: "rubot · Rubot", content: "isi", asset_version: 1)

        assert_includes html, %(<link rel="manifest" href="/manifest.webmanifest">)
        assert_includes html, %(rel="apple-touch-icon")
        assert_includes html, %(name="apple-mobile-web-app-capable" content="yes")
        assert_includes html, %(name="theme-color")
        assert_includes html, "viewport-fit=cover",
                        "a standalone window runs to the notch"
      end

      # A worker only controls the paths under its own, so it is served at the
      # root — and never cached by the browser, or a deploy reaches nobody.
      def test_the_service_worker_is_served_from_the_root_and_not_cached
        channel = Rubot::Channels::Web.new(channel_config: {})
        response = FakeResponse.new

        channel.send(:serve_worker, response)

        assert_equal 200, response.status
        assert_equal "text/javascript; charset=utf-8", response.headers["Content-Type"]
        assert_equal "no-cache", response.headers["Cache-Control"]
        assert_equal "/", response.headers["Service-Worker-Allowed"]
        assert_includes response.body, "rubot-shell-", "the worker has to know its own cache"
      end

      # The cache name is the asset stamp, not a constant: a stylesheet that
      # changed renames the cache, and the installed app rebuilds the shell
      # instead of answering with the copy it kept. A version someone has to
      # remember to bump is a promise that holds only until it is forgotten.
      def test_the_worker_names_its_cache_after_the_assets_it_installs
        channel = Rubot::Channels::Web.new(channel_config: {})
        response = FakeResponse.new

        channel.send(:serve_worker, response)

        refute_includes response.body, "__VERSION__", "the placeholder has to be replaced"
        assert_includes response.body, %(const VERSION = "rubot-shell-#{channel.send(:asset_version)}")
      end

      def test_the_manifest_is_served_with_its_own_type
        channel = Rubot::Channels::Web.new(channel_config: {})
        response = FakeResponse.new

        channel.send(:serve_manifest, response)

        assert_equal 200, response.status
        assert_includes response.headers["Content-Type"], "application/manifest+json"
        assert_equal "rubot", JSON.parse(response.body)["name"]
      end

      # Suppressing a notification because "the app is visible" silenced exactly
      # the ones that matter: an installed app that is backgrounded still
      # reports `visibilityState: "visible"` on iOS, so a locked phone looked
      # like a reader staring at the screen. Focus is the other half — a window
      # somebody is actually in has both.
      def test_the_worker_only_suppresses_a_notification_for_a_window_in_front
        worker = File.read(File.expand_path("../lib/rubot/web/assets/sw.js", __dir__))

        assert_includes worker, 'client.visibilityState === "visible"'
        assert_includes worker, "client.focused",
                        "a backgrounded app still reports visible; focus is what tells them apart"
        assert_includes worker, "payload.force", "the test button must be able to ring anyway"
      end

      # The shell is kept, the conversation is not: a cached answer would be
      # handed to whoever opens the app next, and it would be a lie the moment
      # the turn moved on.
      def test_the_worker_keeps_the_shell_and_never_the_conversation
        worker = File.read(File.expand_path("../lib/rubot/web/assets/sw.js", __dir__))

        assert_includes worker, "/assets/app.css"
        assert_includes worker, "/vendor/htmx.min.js"
        assert_includes worker, %(/turns/), "the stream has to be excluded by path"
        assert_includes worker, 'request.mode === "navigate"'
        assert_includes worker, "caches.open(VERSION)"
      end

      # The page asks for app.css?v=<mtime>, and a lookup that ignored the query
      # answered every deploy with the copy the reader already had: the fix
      # looked like it never landed, on that one device, until the version
      # constant was bumped by hand. The query counts online — the network is the
      # only thing that can answer a URL the cache has never seen — and the loose
      # lookup survives as the offline fallback.
      def test_the_worker_asks_the_network_for_a_file_it_has_not_seen
        worker = File.read(File.expand_path("../lib/rubot/web/assets/sw.js", __dir__))
        lookup = worker[/async function cacheFirst.*?\n\}/m]

        refute_nil lookup, "cacheFirst is missing from sw.js"
        assert_match(/const hit = await cache\.match\(request\);/, lookup,
                     "the versioned URL is the key, or a deploy is invisible")
        assert_match(/cache\.match\(request, \{ ignoreSearch: true \}\)/, lookup,
                     "a stylesheet from an older deploy beats none while offline")
        assert_operator lookup.index("cache.match(request);"), :<, lookup.index("ignoreSearch"),
                        "online first; the loose lookup is only after the network said no"
      end

      # Registering is the only thing the page does about it, and it must not
      # stand in front of the first paint.
      def test_the_page_registers_the_worker_after_load
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, 'navigator.serviceWorker.register("/sw.js")'
        assert_includes js, 'window.addEventListener("load"'
      end

      # Every file in the shell is served under one version, so the stamp has to
      # move when any of them changes. It was the stylesheet's mtime, which left
      # a script change invisible to any browser that already had app.js cached;
      # the worker is in the list for the same reason.
      def test_the_asset_stamp_follows_the_newer_file
        channel = Rubot::Channels::Web.new(channel_config: {})
        assets = File.expand_path("../lib/rubot/web/assets", __dir__)
        newest = %w[app.css app.js sw.js].map { |name| File.mtime(File.join(assets, name)).to_i }.max

        assert_equal newest, channel.send(:asset_version)
      end
    end
  end
end
