// The shell a phone installs: rubot's own surface, never the conversation.
//
// A chat page is the wrong thing to keep: it is private, it is written for one
// session id, and it changes on every turn. What a cold start needs is the CSS,
// the scripts and the fonts, so the page that comes back from the network is
// already dressed — and an offline start says so in rubot's own clothes instead
// of the browser's grey dinosaur.
const VERSION = "rubot-shell-v2";

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

async function cacheFirst(request) {
  const cache = await caches.open(VERSION);
  const hit = await cache.match(request, { ignoreSearch: true });
  if (hit) return hit;

  const response = await fetch(request);
  if (response.ok) cache.put(request, response.clone());
  return response;
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
