// The shell a phone installs: rubot's own surface, never the conversation.
//
// A chat page is the wrong thing to keep: it is private, it is written for one
// session id, and it changes on every turn. What a cold start needs is the CSS,
// the scripts and the fonts, so the page that comes back from the network is
// already dressed — and an offline start says so in rubot's own clothes instead
// of the browser's grey dinosaur.
// The cache this worker owns. The number is stamped by the server from the
// modification time of the files below (see `serve_worker`), so a change to the
// stylesheet or a script renames the cache by itself — a version nobody has to
// remember to bump, which is the only kind that stays true.
const VERSION = "rubot-shell-__VERSION__";

// Everything the first paint needs. The cache entry is looked up with the query
// string ignored, so an `app.css?v=1700000000` after a deploy still hits, and
// the version bump above is what forces a fresh copy.
const SHELL = [
  "/assets/app.css",
  "/assets/app.js",
  "/assets/source-serif-4-var.woff2",
  "/assets/source-serif-4-var-italic.woff2",
  "/assets/martian-mono-var.woff2",
  "/assets/icon-192.png",
  "/assets/icon-512.png",
  // Named by the push handler, so it has to be on the device before a
  // notification arrives — an uncached badge would paint the notification
  // without its mark.
  "/assets/badge.png",
  "/vendor/htmx.min.js",
  "/vendor/htmx-sse.js",
  "/vendor/alpine.min.js"
];

// Shown when a navigation cannot reach the server at all. It carries no data
// from the conversation — there is nothing on this device to leak.
const OFFLINE = `<!doctype html>
<html lang="id"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>rubot · offline</title>
<style>
  html,body{height:100%;margin:0}
  body{display:flex;align-items:center;justify-content:center;background:#2b332f;color:#d3c6aa;
       font-family:Georgia,serif;text-align:center;padding:2rem;line-height:1.6}
  p{margin:0.4rem 0;max-width:24rem}
  .dim{color:#939e8b;font-size:0.9rem}
</style></head>
<body><div>
  <p>rubot sedang tidak tersambung.</p>
  <p class="dim">Server-nya yang tidak menjawab, bukan sesinya yang hilang.
     Coba lagi begitu jaringannya kembali.</p>
</div></body></html>`;

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(VERSION)
      // A single missing file must not fail the whole install: a font that was
      // renamed should cost a fallback, not the service worker.
      .then((cache) => Promise.all(SHELL.map((url) => cache.add(url).catch(() => null))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== VERSION).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  // The turn stream is the conversation happening right now. It is not a
  // document, it is not reusable, and a cached copy would hand the next reader
  // someone else's answer.
  if (url.pathname.startsWith("/turns/")) return;

  if (url.pathname.startsWith("/assets/") || url.pathname.startsWith("/vendor/")) {
    event.respondWith(cacheFirst(request));
    return;
  }

  if (request.mode === "navigate") {
    event.respondWith(networkFirst(request));
  }
});

// The shell is asked for with the mtime in the query string, so a cache lookup
// that ignores the query answers every deploy with the copy from before it: the
// HTML asks for app.css?v=1794250951 and the worker hands back the file the
// reader already had. The page then looks like the fix never landed — a stale
// header, a stale scroll handler — until the version constant below is bumped by
// hand. So the query counts: an unseen URL is a cache miss, and the network is
// the only thing that can answer it.
async function cacheFirst(request) {
  const cache = await caches.open(VERSION);
  const hit = await cache.match(request);
  if (hit) return hit;

  try {
    const response = await fetch(request);
    if (!response.ok) return response;

    // One copy per file: the versioned URL of the previous deploy is now dead
    // weight, and nothing will ever ask for it again. The bare URL from SHELL is
    // kept — that is the copy an offline start falls back to.
    const path = new URL(request.url).pathname;
    const stale = (await cache.keys()).filter((key) => {
      const other = new URL(key.url);
      return other.pathname === path && other.search && key.url !== request.url;
    });
    await Promise.all(stale.map((key) => cache.delete(key)));
    await cache.put(request, response.clone());
    return response;
  } catch (error) {
    // Offline. The page cannot be fetched either, so a stylesheet from an older
    // deploy is worth more than none at all: ignore the query and hand over the
    // copy that is there.
    const fallback = await cache.match(request, { ignoreSearch: true });
    if (fallback) return fallback;

    throw error;
  }
}

async function networkFirst(request) {
  try {
    return await fetch(request);
  } catch (_error) {
    // The page itself is never replayed from a cache — it would show a
    // conversation that is no longer true — so an unreachable server gets the
    // offline note instead.
    return new Response(OFFLINE, { headers: { "Content-Type": "text/html; charset=utf-8" } });
  }
}

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------
//
// A push arrives when something happened while the app was closed — a reminder
// fired, a scheduled turn finished. The payload is already opened by the
// browser: the server sealed it to a key only this device holds, so there is
// nothing to decrypt here.
//
// The one rule the handler enforces is that a notification is for a reader who
// is not looking. A visible rubot window means the news is on screen, and
// buzzing about it would be noise about something already seen.
//
// A payload may carry `force` to opt out of that rule. The test button is
// pressed from a page that is, by definition, on screen, and swallowing its
// notification would hide the one thing that button exists to prove.

self.addEventListener("push", (event) => {
  event.waitUntil(announce(event.data));
});

async function announce(data) {
  let payload = { title: "rubot", body: "" };
  if (data) {
    try {
      payload = data.json();
    } catch (_error) {
      // A sender that did not promise JSON still deserves to be shown.
      payload = { title: "rubot", body: data.text() };
    }
  }

  const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
  if (!payload.force && windows.some((client) => client.visibilityState === "visible")) return;

  await self.registration.showNotification(payload.title || "rubot", {
    body: payload.body || "",
    icon: "/assets/icon-192.png",
    // The status-bar mark is an alpha mask, not a picture: the system paints it
    // white (or tints it), so a coloured icon with its own background arrives
    // as a solid block. `badge.png` is this app's own mark with the background
    // taken out — the same artwork, outlined for that one slot.
    badge: "/assets/badge.png",
    // The tag collapses a second notification for the same persona into the
    // first instead of stacking a tower of them on the lock screen.
    tag: payload.tag || "rubot",
    data: { url: payload.url || "/" }
  });

  // "Accepted by the push service" and "shown on the device" are different
  // events, and only this side knows the second one happened. A page that is
  // waiting to be told — the test button — gets the answer.
  for (const client of windows) {
    client.postMessage({ type: "rubot-push-shown", tag: payload.tag || "rubot" });
  }
}

self.addEventListener("notificationclick", (event) => {
  event.notification.close();

  const target = new URL(event.notification.data && event.notification.data.url ? event.notification.data.url : "/",
    self.location.origin).href;

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const open = windows.find((client) => client.url.startsWith(self.location.origin));
    if (open) {
      // A tab that was already on rubot is moved to the conversation the
      // notification is about, then brought forward — opening a second window
      // beside the first would leave the news split across two of them.
      if ("navigate" in open) {
        try { await open.navigate(target); } catch (_error) { /* not ours to steer */ }
      }
      return open.focus();
    }

    return self.clients.openWindow(target);
  })());
});
