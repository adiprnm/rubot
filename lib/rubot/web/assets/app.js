// Alpine glue for the chat shell. Everything that renders HTML lives on the
// Ruby side; this file only wires the composer and keeps the active-turn
// marker in sync with the SSE connection.
document.addEventListener("alpine:init", () => {
  Alpine.store("turn", { active: null });

  Alpine.data("composer", () => ({
    text: "",
    // Set the moment the button is pressed to stop, cleared when the server
    // answers. The turn is still live during that round trip — it stays live
    // until the stream closes — so without this the button looked untouched
    // and a second press simply repeated the request.
    stopping: false,

    get busy() {
      return Alpine.store("turn").active !== null;
    },

    // A phone has no Shift to hold and no Enter that means "new line" by
    // convention: the one key the software keyboard offers is how a second
    // line gets started, so it must not send. Sending is the button's job
    // there. A pointer that cannot hover is the honest signal for a device
    // with an on-screen keyboard — a user-agent string is only a guess.
    get touchOnly() {
      return window.matchMedia("(hover: none) and (pointer: coarse)").matches;
    },

    init() {
      // The field promises Enter/Shift+Enter, which is only true of a device
      // that has both keys.
      if (this.touchOnly && this.$refs.input) this.$refs.input.placeholder = "Tulis pesan…";
    },

    keydown(event) {
      if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
      if (this.touchOnly) return;
      event.preventDefault();
      this.send();
    },

    send() {
      const text = this.text.trim();
      if (!text || this.stopping) return;

      // The reader's own prompt is one they expect to see land, so it takes the
      // thread back to the end even if they had been reading further up.
      jumpToBottom();

      const active = Alpine.store("turn").active;
      if (active) {
        // The turn already running owns the session; hand the text over
        // instead of queueing a second turn behind it. On a phone this is the
        // only way to steer at all: Enter there makes a new line, and the
        // keyboard offers no chord for "send anyway".
        const body = new URLSearchParams({ text });
        this.text = "";
        fetch(`/turns/${active}/steer`, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body,
        });
        return;
      }

      this.$refs.form.requestSubmit();
    },

    // Stopping is a request, not a fact: the turn keeps running until the
    // server has acted on it. The button says so and stops accepting presses
    // for the round trip, then falls back to whatever the store says — the
    // stream closes on its own when the turn really ends, and that is what
    // takes the button out of the page again.
    async stop() {
      const active = Alpine.store("turn").active;
      if (!active || this.stopping) return;

      this.stopping = true;
      try {
        await fetch(`/turns/${active}/stop`, { method: "POST" });
      } catch (_error) {
        // The turn is still running if the request never landed, so the
        // button must not stay stuck on a label that is no longer true.
      } finally {
        this.stopping = false;
      }
    },

    // What the stop button reads. The send button needs no equivalent: its
    // label is the same word whether the session is free or busy, and only
    // what the press does with the text changes.
    get stopLabel() {
      return this.stopping ? "Membatalkan…" : "Batal";
    },
  }));
});

// Clear the composer once htmx actually accepted the turn.
document.addEventListener("htmx:afterRequest", (event) => {
  const el = event.detail.elt;
  if (!event.detail.successful) return;
  if (!(el instanceof Element) || !el.classList.contains("composer")) return;

  const data = Alpine.$data(el);
  if (data && "text" in data) data.text = "";
});

// A prompt the server refused — most often the 409 that says a turn is still
// running — is the one case where the text stays in the field and nothing
// appears in the thread. Said nowhere, the reader is left pressing a button
// that looks broken, so the fragment the server sent is placed under the
// composer instead.
document.addEventListener("htmx:responseError", (event) => {
  const el = event.detail.elt;
  if (!(el instanceof Element) || !el.classList.contains("composer")) return;

  const slot = document.getElementById("composer-notice");
  if (!slot) return;

  // A refusal that carries markup says its own reason (the 409 does). A crash
  // answers with plain text, which is no sentence for a reader — so the status
  // is said in words instead of left as "internal error" on the page.
  const xhr = event.detail.xhr || {};
  const body = (xhr.responseText || "").trim();
  slot.innerHTML = body.includes("<")
    ? body
    : `<div class="notice"><div class="error">Server gagal memproses pesan itu (${xhr.status || "?"}). Teksmu masih di kolom, coba kirim lagi.</div></div>`;
  slot.hidden = false;
});

// A later accepted prompt clears that notice: it described a moment that has
// passed, and leaving it under the field would read as a standing warning.
document.addEventListener("htmx:beforeRequest", (event) => {
  const el = event.detail.elt;
  if (!(el instanceof Element) || !el.classList.contains("composer")) return;

  // A press on the send button takes the same road as Enter, minus the store
  // that `send()` touches first: the reader asked for their prompt to appear,
  // so the thread is pinned before the swap that appends it.
  jumpToBottom();

  const slot = document.getElementById("composer-notice");
  if (!slot) return;
  slot.innerHTML = "";
  slot.hidden = true;
});

// The SSE extension closes the stream when Ruby sends the `done` event; that
// is also the signal that the session is free again. Marking the turn done
// retires its blinking cursor, and the band above the composer — the row that
// said the turn was still running — is emptied: it described a moment, and the
// moment is over.
for (const name of ["htmx:sseClose", "htmx:sseError"]) {
  document.addEventListener(name, () => {
    Alpine.store("turn").active = null;
    document
      .querySelectorAll(".turn:not(.is-done)")
      .forEach((turn) => turn.classList.add("is-done"));

    const working = document.getElementById("working");
    if (working) working.replaceChildren();

    // The band above the field just lost its row, which makes the thread taller
    // by the same amount: a reader who was following is no longer at the end of
    // it, so they are put back where the conversation finished.
    followTurn();
  });
}

// Whether the thread is pinned to its end decides who gets the last word when
// something arrives. A reader who has scrolled up is reading: content appended
// below them is nothing to do with them, and a page that yanks itself back down
// on every chunk is a page arguing with the scroll wheel. So the position is
// remembered, and only a thread already at its end follows the turn.
const BOTTOM_SLACK = 40; // px — "at the end" rather than "exactly at the end"

function threadEl() {
  return document.getElementById("thread");
}

// Read, never remembered: the reader's own scrolling is what decides this.
function noteThreadPosition(thread) {
  const distance = thread.scrollHeight - thread.scrollTop - thread.clientHeight;
  thread.dataset.pinned = distance <= BOTTOM_SLACK ? "true" : "false";
}

function followTurn() {
  const thread = threadEl();
  if (!thread || thread.dataset.pinned !== "true") return;
  thread.scrollTop = thread.scrollHeight;
}

// The two moments the reader asked for the bottom themselves — opening a
// session, sending a prompt — are the only ones allowed to overrule them.
function jumpToBottom() {
  const thread = threadEl();
  if (!thread) return;
  thread.dataset.pinned = "true";
  thread.scrollTop = thread.scrollHeight;
}

// A conversation is named by its first prompt, and that name arrives over the
// stream once the turn has been saved. The header carries it in `data-title` in
// the shape the tab wants, so adopting it needs no second source of truth.
function syncDocumentTitle() {
  const head = document.getElementById("chat-head");
  if (!head || !head.dataset.title) return;
  document.title = `rubot · ${head.dataset.title}`;
}

// ---------------------------------------------------------------------------
// The on-screen keyboard
// ---------------------------------------------------------------------------
//
// A phone's keys cover the bottom of the screen without touching the layout
// viewport on every browser that has them: the shell kept its full height and
// the field sat behind the keys. The page cannot scroll to reveal it — it is a
// page that never scrolls, on purpose (see `html, body` in app.css) — so the
// shell has to end where the keys begin instead.
//
// `visualViewport` is the box the reader can actually see. When it is shorter
// than the layout viewport, the difference is a keyboard (or a zoom, handled
// below), and the shell follows it. Browsers that resize the *layout* viewport
// for the keyboard — those honouring `interactive-widget=resizes-content` —
// need nothing from here: `dvh` is already right, and writing the same number
// costs nothing.
const KEYBOARD_SLACK = 80; // px — a viewport this much shorter is keys, not a toolbar

function fitToKeyboard() {
  const view = window.visualViewport;
  if (!view) return;

  const root = document.documentElement;
  // Pinch-zoom shrinks the visual viewport as well, and the shell must not
  // follow that: a reader who zoomed in would get a two-centimetre app.
  if (view.scale > 1.01) {
    root.style.removeProperty("--vvh");
    return;
  }

  const shrunk = window.innerHeight - view.height > KEYBOARD_SLACK;
  if (shrunk) {
    root.style.setProperty("--vvh", `${Math.round(view.height)}px`);
    // The thread just got shorter, so a reader who was sitting at its end is no
    // longer there: keep them with the conversation they were following.
    followTurn();
  } else {
    // Nothing over the shell: hand the height back to `dvh`, which knows about
    // the browser's own toolbars better than a number measured once.
    root.style.removeProperty("--vvh");
  }
}

if (window.visualViewport) {
  window.visualViewport.addEventListener("resize", fitToKeyboard);
  // iOS pans the visual viewport instead of resizing the layout one, and the
  // pan arrives as a scroll on the same object.
  window.visualViewport.addEventListener("scroll", fitToKeyboard);
  fitToKeyboard();
}

// A chunk arrives every few hundred milliseconds while a turn runs, and the
// thread grows under it. Following is the default only from the end.
document.addEventListener("htmx:sseMessage", () => followTurn());

document.addEventListener("htmx:afterSwap", (event) => {
  const el = event.detail.elt;
  // An older page arrives *above* the reader. Jumping to the bottom would throw
  // them out of the place they were reading, so the prepend is left to the
  // handler below, which keeps them where they are.
  if (el instanceof Element && el.closest(".history-more")) return;
  followTurn();
});
document.addEventListener("htmx:afterSwap", syncDocumentTitle);

// A conversation is read from its end. The page only draws the tail of it, so
// the thread starts at the bottom — otherwise opening a session would put the
// reader in front of its oldest message.
document.addEventListener("DOMContentLoaded", () => {
  const thread = threadEl();
  if (!thread) return;
  jumpToBottom();
});

// Scroll events do not bubble, so the one listener that keeps the pin honest
// listens on the way down instead of on the thread itself. It has to survive
// whatever the thread does, which is why it is not attached to the element.
document.addEventListener(
  "scroll",
  (event) => {
    const el = event.target;
    if (el instanceof Element && el.id === "thread") noteThreadPosition(el);
  },
  { capture: true, passive: true }
);

// Prepending a page moves everything below it down, which would slide the
// conversation out from under the reader mid-scroll. What is preserved is the
// distance from the bottom: content added above the viewport cannot change it,
// so the reader stays on the sentence they were reading.
document.addEventListener("htmx:beforeSwap", (event) => {
  const el = event.detail.elt;
  if (!(el instanceof Element) || !el.closest(".history-more")) return;

  const thread = document.getElementById("thread");
  if (!thread) return;
  thread.dataset.holdFromBottom = thread.scrollHeight - thread.scrollTop;
});

document.addEventListener("htmx:afterSwap", (event) => {
  const el = event.detail.elt;
  if (!(el instanceof Element) || !el.closest(".history-more")) return;

  const thread = document.getElementById("thread");
  if (!thread || thread.dataset.holdFromBottom === undefined) return;

  const gap = Number(thread.dataset.holdFromBottom);
  delete thread.dataset.holdFromBottom;
  thread.scrollTop = thread.scrollHeight - gap;
});

// A running thought or tool call carries the moment it started, and the clock
// beside it is filled in here. Nothing is sent from the server for it: the
// seconds of a wait are the one thing the browser already knows how to count,
// and both rules — a thought under three seconds, a call under three seconds —
// are exactly "say nothing until it has been long enough to notice".
function fmtClock(seconds) {
  const total = Math.floor(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;

  const parts = [];
  if (hours) parts.push(`${hours}h`);
  if (minutes || hours) parts.push(`${minutes}m`);
  if (secs || !parts.length) parts.push(`${secs}s`);
  return parts.join(" ");
}

function tickClocks() {
  const now = Date.now() / 1000;
  for (const row of document.querySelectorAll("[data-since]")) {
    const clock = row.querySelector(".live-clock");
    if (!clock) continue;

    // A row for a turn that is already over keeps its last reading rather
    // than counting on past the end of the work it measured.
    if (row.closest(".turn.is-done")) continue;

    const elapsed = now - Number(row.dataset.since);
    const threshold = Number(row.dataset.threshold || 3);
    clock.textContent = elapsed >= threshold ? fmtClock(elapsed) : "";
  }
}

setInterval(tickClocks, 500);

// ---------------------------------------------------------------------------
// Lightbox
// ---------------------------------------------------------------------------
//
// Any picture in the thread can be opened full size. The handler is on the
// document rather than on each image because the thread is written by the
// server and swapped in pieces: a listener bound at load time would go stale
// on the first turn, while a delegated one keeps working for every picture
// that has ever arrived — including the ones an answer brings.
function openLightbox(url, name) {
  const box = document.getElementById("lightbox");
  if (!box) return;

  const image = box.querySelector(".lightbox-image");
  const link = box.querySelector(".lightbox-download");
  if (!image || !link) return;

  image.src = url;
  image.alt = name || "";
  link.href = url;
  link.download = name || "";

  box.hidden = false;
  box.classList.add("is-open");
  // The page behind must not scroll under the sheet.
  document.body.classList.add("lightbox-open");
  const close = box.querySelector(".lightbox-close");
  if (close) close.focus();
}

function closeLightbox() {
  const box = document.getElementById("lightbox");
  if (!box || box.hidden) return;

  box.hidden = true;
  box.classList.remove("is-open");
  document.body.classList.remove("lightbox-open");

  // Drop the source so a closed sheet holds no decoded image in memory.
  const image = box.querySelector(".lightbox-image");
  if (image) image.removeAttribute("src");
}

document.addEventListener("click", (event) => {
  const trigger = event.target.closest("[data-lightbox]");
  if (trigger) {
    event.preventDefault();
    openLightbox(trigger.dataset.lightbox, trigger.dataset.name);
    return;
  }

  // The scrim closes it; a click inside the figure must not.
  if (event.target.id === "lightbox" || event.target.closest(".lightbox-close")) {
    event.preventDefault();
    closeLightbox();
  }
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") closeLightbox();
});

// ---------------------------------------------------------------------------
// Copy a code block
// ---------------------------------------------------------------------------
//
// The button is written by the server, one per block, so it is already in the
// page for a block that arrived mid-stream and nothing has to watch the DOM
// for it. The text comes back out of the block's own <code>: highlighting only
// wraps the text in spans, it never rewrites it, so `textContent` is exactly
// what the model wrote — indentation and quotes included.
//
// The clipboard API is the path that needs no selection, but it only exists on
// a secure origin. The app is often reached over plain http on a tailnet, so
// there is a fallback that copies through a throwaway textarea.

// What the button says when it is doing nothing. The mark it shows is only a
// mark, so the words live in the label and in the tooltip both — and the
// receipt below has to be able to hand them back.
const COPY_PROMPT = "Salin isi blok kode";

function copyThroughSelection(text) {
  const area = document.createElement("textarea");
  area.value = text;
  area.setAttribute("readonly", "");
  // Fixed and out of sight rather than `hidden`: a hidden element cannot be
  // selected, and being selected is the whole point here.
  area.style.position = "fixed";
  area.style.top = "-1000px";
  area.style.opacity = "0";
  document.body.appendChild(area);
  area.select();

  let copied = false;
  try {
    copied = document.execCommand("copy");
  } catch (_error) {
    copied = false;
  }
  area.remove();
  return copied;
}

async function copyText(text) {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (_error) {
      // A refused permission is not a dead end: the fallback still has a
      // selection to work with.
    }
  }
  return copyThroughSelection(text);
}

document.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-copy]");
  if (!button) return;

  const block = button.closest(".code-block");
  const code = block ? block.querySelector("pre.code code") : null;
  if (!code) return;

  const copied = await copyText(code.textContent);
  const label = copied ? "Isi blok kode tersalin" : "Gagal menyalin isi blok kode";

  // The mark is the whole of what is seen, so the class on the button is what
  // tells a copy from a failure; the label behind it is what a screen reader
  // reads, and the tooltip is what a pointer explains it with.
  button.classList.toggle("is-copied", copied);
  button.classList.toggle("is-failed", !copied);
  button.title = label;
  const spoken = button.querySelector(".sr-only");
  if (spoken) spoken.textContent = label;

  // The mark is a receipt, not a state: the block is still there to be copied
  // again, and the button goes back to saying what it does. A second press
  // inside the window restarts the wait rather than letting the first end it.
  clearTimeout(button.copiedTimer);
  button.copiedTimer = setTimeout(() => {
    button.classList.remove("is-copied", "is-failed");
    button.title = COPY_PROMPT;
    if (spoken) spoken.textContent = COPY_PROMPT;
  }, 1400);
});

// A persona dialog — the new one in the rail, the edit one in the sidebar —
// dims the page behind it, and the dimmed part is a way out. `<details>`
// closes on its own summary, so only the two things it does not handle are
// wired here: a click on the backdrop and the Escape key. Without this a
// dialog could only be dismissed by the one button it was opened with, which
// the backdrop is covering.
const PERSONA_DIALOG = "details.rail-new[open], details.side-edit[open]";

document.addEventListener("click", (event) => {
  const open = document.querySelector(PERSONA_DIALOG);
  if (!open) return;

  if (open.querySelector("summary")?.contains(event.target)) return;
  if (open.querySelector(".rail-panel")?.contains(event.target)) return;

  open.open = false;
});

document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return;

  const open = document.querySelector(PERSONA_DIALOG);
  if (open) open.open = false;
});

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------
//
// The head script already picked a theme before the first paint; this only has
// to keep the buttons showing which one it is, and to record a change.
//
// The choice belongs to the reader, so it lives in localStorage and never
// reaches the server: two people reading the same conversation should each get
// their own colours. Until one of them chooses, the system preference decides —
// and it is re-read on change, so a phone that switches to its night palette at
// sunset takes rubot with it.
//
// `color-scheme` is set alongside `data-theme` so the browser's own scrollbars,
// form controls and canvas follow the choice too.
const THEME_KEY = "rubot-theme";
const THEMES = ["everforest", "dark", "light"];

function applyTheme(name) {
  const theme = THEMES.includes(name) ? name : "everforest";
  document.documentElement.setAttribute("data-theme", theme);
  document.documentElement.style.colorScheme = theme === "light" ? "light" : "dark";

  document.querySelectorAll("[data-theme-choice]").forEach((button) => {
    button.setAttribute("aria-pressed", button.dataset.themeChoice === theme ? "true" : "false");
  });

  // The address bar of an installed app takes its colour from here, and it is
  // the one piece of the chrome the page can still paint.
  const bar = document.querySelector('meta[name="theme-color"]');
  if (bar) {
    bar.setAttribute("content", theme === "light" ? "#f3efda" : (theme === "dark" ? "#1b1f24" : "#2b332f"));
  }
}

function currentTheme() {
  return document.documentElement.getAttribute("data-theme") || "everforest";
}

document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-theme-choice]");
  if (!button) return;

  const theme = button.dataset.themeChoice;
  try { localStorage.setItem(THEME_KEY, theme); } catch (_error) { /* private mode */ }
  applyTheme(theme);
});

if (window.matchMedia) {
  window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", (event) => {
    // Only while the reader has expressed no preference of their own.
    let saved = null;
    try { saved = localStorage.getItem(THEME_KEY); } catch (_error) { /* private mode */ }
    if (!saved) applyTheme(event.matches ? "light" : "everforest");
  });
}

// The picker is drawn inside the page, and htmx rewrites parts of it: the state
// has to be re-applied whenever the buttons arrive.
document.addEventListener("htmx:afterSwap", () => applyTheme(currentTheme()));
applyTheme(currentTheme());

// ---------------------------------------------------------------------------
// Installed app
// ---------------------------------------------------------------------------
//
// The worker only keeps the shell — styles, scripts, fonts — so a cold start is
// dressed before the network answers, and a server that is down says so on a
// page of rubot's own instead of the browser's. It is registered after `load`
// so the install never competes with the first paint.
//
// A failure here is not worth a word on the page: rubot works without it, and
// the browser only offers the worker over a secure origin anyway.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
  });
}
