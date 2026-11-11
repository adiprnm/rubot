// Alpine glue for the chat shell. Everything that renders HTML lives on the
// Ruby side; this file only wires the composer and keeps the active-turn
// marker in sync with the SSE connection.
document.addEventListener("alpine:init", () => {
  Alpine.store("turn", { active: null });

  Alpine.data("composer", () => ({
    text: "",
    // Paragraphs taken from the conversation with the quote mark beside them.
    // Each one rides above the field as a chip and is stitched into the
    // message when it is sent, so the field itself only ever holds what the
    // reader typed.
    quotes: [],
    quoteSeq: 0,
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
        const body = new URLSearchParams({ text: this.compose(text) });
        this.text = "";
        this.quotes = [];
        fetch(`/turns/${active}/steer`, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body,
        });
        return;
      }

      this.$refs.form.requestSubmit();
    },

    // A block handed over by its quote mark. `source` is the block's own
    // Markdown — what will be sent — while `preview` is the text the page
    // already drew, so the chip does not show a paragraph's `**marks**` and
    // backticks at the reader. `kind` is what the block is, when saying it
    // helps: a list arrives as "Daftar · 6 butir", a single item as "Butir 3".
    // The same block twice is one piece of context, not two, so a repeated
    // press only puts the caret back.
    quote(source, preview, kind) {
      const body = String(source || "").replace(/\r\n?/g, "\n").trim();
      if (!body) return;
      if (!this.quotes.some((entry) => entry.text === body)) {
        const shown = String(preview || "").replace(/\s+/g, " ").trim();
        this.quotes.push({ id: (this.quoteSeq += 1), text: body, preview: shown || body, kind: String(kind || "") });
      }
      this.focusInput();
    },

    unquote(id) {
      this.quotes = this.quotes.filter((entry) => entry.id !== id);
      // The button that was pressed has just left the page, which would drop
      // the caret on the body; the field is where the reader was heading.
      this.focusInput();
    },

    // What the reader will actually send: the quotes first, as Markdown
    // quotations (the form the agent already reads), then what they typed.
    compose(text) {
      const body = String(text || "").trim();
      const quoted = this.quotes
        .map((entry) => entry.text.split("\n").map((line) => (line ? `> ${line}` : ">")).join("\n"))
        .join("\n\n");
      return quoted ? `${quoted}\n\n${body}` : body;
    },

    // The count is what a screen reader gets; the chips themselves say it to
    // everyone else. "kutipan", not "paragraf": a list is quoted as a block
    // too, and the label should hold for either.
    get quoteStatus() {
      const count = this.quotes.length;
      if (count === 0) return "";
      return count === 1 ? "1 kutipan" : `${count} kutipan`;
    },

    // Quoting is a prelude to typing, so the field takes the caret — at the
    // end, where a message continues rather than where it began.
    focusInput() {
      const input = this.$refs.input;
      if (!input) return;
      input.focus({ preventScroll: true });
      input.setSelectionRange(input.value.length, input.value.length);
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
  // The quotes were stitched into the message on its way out (see
  // `htmx:configRequest`), so they have left with it. A refused turn never
  // reaches here, which is what keeps them available for the retry.
  if (data && "quotes" in data) data.quotes = [];
});

// A turn leaves with the quoted paragraphs in front of what was typed. The
// field belongs to the reader, so the quote is added to the request rather
// than written into the field: htmx has serialised the form by the time this
// runs, which is exactly why replacing the value here is safe and why the
// textarea can keep showing only the typed text.
document.addEventListener("htmx:configRequest", (event) => {
  const el = event.detail.elt;
  if (!(el instanceof Element) || !el.classList.contains("composer")) return;

  const data = Alpine.$data(el);
  if (!data || !data.quotes || data.quotes.length === 0) return;
  event.detail.parameters.message = data.compose(data.text);
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
//
// Two rules decide *which* event means that, and both were learned on a phone.
//
// The element a stream belongs to says what it is about: the page carries a
// second, idle stream for news about other conversations (`/events`), and it
// lives as long as the page does. Its closing says nothing about a turn, so
// only a stream hanging off a `.turn` retires anything.
//
// And an *error* is not a close. A phone that puts the app down freezes its
// sockets; coming back reopens them, and htmx reports the dropped connection
// as `htmx:sseError` a moment before it reconnects. Retiring the turn there was
// the reason "Working…" and the tool call's clock sometimes never appeared
// after the app went to the background: the band was emptied and the turn was
// marked done, so the row never came back — and the live clock only fills rows
// in a turn that is not done. The stream that returns is the one that knows
// whether the work finished while the page was away, and it says so at once.
function turnStreamOf(event) {
  const elt = event.detail && event.detail.elt;
  if (!(elt instanceof Element)) return null;
  return elt.closest(".turn");
}

// The turn is over. One row of the page described a moment, and the moment is
// over.
function retireTurn(turn) {
  turn.classList.add("is-done");
  Alpine.store("turn").active = null;

  const working = document.getElementById("working");
  if (working) working.replaceChildren();

  // The band above the field just lost its row, which makes the thread taller
  // by the same amount: a reader who was following is no longer at the end of
  // it, so they are put back where the conversation finished.
  followTurn();
}

document.addEventListener("htmx:sseClose", (event) => {
  const turn = turnStreamOf(event);
  if (!turn) return;

  retireTurn(turn);
});

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
// The height of the shell
// ---------------------------------------------------------------------------
//
// A phone's keys cover the bottom of the screen without touching the layout
// viewport on every browser that has them: the shell kept its full height and
// the field sat behind the keys. The page cannot scroll to reveal it — it is a
// page that never scrolls, on purpose (see `html, body` in app.css) — so the
// shell has to end where the keys begin instead.
//
// `visualViewport` is the box the reader can actually see, and it is the only
// honest number straight after a navigation. `dvh` is a *dynamic* unit: the
// browser is free to publish it before it has settled on the things it is
// dynamic about, and installed as an app it does — opening a session laid the
// shell out at the height of a window that was no longer there, which dropped
// the field and the figures under the bottom edge. Every mark of that was gone
// the moment the browser recounted, and the thing that made it recount was
// touching the field and leaving it: the keyboard opening and closing is a
// visual viewport event, which is this function.
//
// So the shell follows this box always, not only when it is short enough to be
// a keyboard. `dvh` stays in the stylesheet as the height for the frames before
// this runs, and for a browser without a visual viewport at all.
function fitToViewport() {
  const view = window.visualViewport;
  if (!view) return;

  const root = document.documentElement;
  // Pinch-zoom shrinks the visual viewport as well, and the shell must not
  // follow that: a reader who zoomed in would get a two-centimetre app.
  if (view.scale > 1.01) {
    root.style.removeProperty("--vvh");
    return;
  }

  const height = `${Math.round(view.height)}px`;
  if (root.style.getPropertyValue("--vvh") === height) return;

  root.style.setProperty("--vvh", height);

  // The shell just changed height, so a reader who was sitting at the end of
  // the thread is no longer there: keep them with the conversation they were
  // following.
  followTurn();
}

if (window.visualViewport) {
  window.visualViewport.addEventListener("resize", fitToViewport);
  // iOS pans the visual viewport instead of resizing the layout one, and the
  // pan arrives as a scroll on the same object.
  window.visualViewport.addEventListener("scroll", fitToViewport);
  fitToViewport();
}

// Two moments the first measurement cannot cover. `load` is after the browser
// has had a paint to settle the toolbar and the safe area; `pageshow` is a page
// coming back out of the back/forward cache, laid out for the window it had
// when it was put away. One more look after the next paint catches a toolbar
// that was still animating through the one at `load`.
window.addEventListener("load", () => {
  fitToViewport();
  requestAnimationFrame(fitToViewport);
});
window.addEventListener("pageshow", fitToViewport);

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

// A search result opens the conversation at the message it found. The server
// has already marked that entry — a turn wraps several messages, so the message
// index cannot name an element — and the mark is where the reader lands.
// Landing is not followed by the usual jump to the bottom: that would undo the
// one thing the reader clicked.
function landOnSearchHit() {
  const target = document.querySelector(".thread .is-landed");
  if (!(target instanceof Element)) return false;

  // Centred rather than aligned to the top: the prompt that led to the hit is
  // usually worth seeing too, and the ring already says which entry it is.
  target.scrollIntoView({ block: "center" });
  return true;
}

// A conversation is read from its end. The page only draws the tail of it, so
// the thread starts at the bottom — otherwise opening a session would put the
// reader in front of its oldest message.
document.addEventListener("DOMContentLoaded", () => {
  if (landOnSearchHit()) return;

  const thread = threadEl();
  if (!thread) return;
  jumpToBottom();
});

// Ctrl/Cmd+K is where a search is expected to be. The dialog is a real modal, so
// opening it is one call and the field is focused inside it; escape closes it
// without any help from here.
//
// The event comes first: on a phone the button that opens this lives in the
// drawer, and the drawer has to get out of the way — the dialog is modal, so a
// panel left open behind it would only reappear on close, looking like the
// dialog had not been dismissed. The page owns that state (see index.erb), which
// is why this asks rather than reaches into it.
function openSearch() {
  const dialog = document.getElementById("search-dialog");
  if (!(dialog instanceof HTMLDialogElement)) return false;

  window.dispatchEvent(new CustomEvent("rubot:search"));

  if (!dialog.open) dialog.showModal();

  const input = dialog.querySelector(".search-input");
  if (input instanceof HTMLInputElement) {
    input.focus();
    input.select();
  }
  return true;
}

function closeSearch() {
  const dialog = document.getElementById("search-dialog");
  if (dialog instanceof HTMLDialogElement && dialog.open) dialog.close();
}

// ---------------------------------------------------------------------------
// Swiping the drawer
// ---------------------------------------------------------------------------
//
// The handle in the header sits in a corner a thumb does not reach, so the
// drawer also answers a gesture: a finger travelling left to right pulls the
// roster in — the drawer is on the left, so it is pulled toward the side it
// came from — and a finger travelling back toward the left pushes it away
// again. Nothing is drawn for this, and there is nothing to learn.
//
// The gesture is read once and then spent. Half a swipe must not toggle twice,
// and what the finger does after the drawer has begun to move is no longer a
// swipe but a finger on a moving panel.
const DRAWER_QUERY = "(max-width: 860px)";
const DRAWER_TRAVEL = 44; // px of travel before the gesture means anything
const DRAWER_SLOPE = 1.6; // how far horizontal has to beat vertical

let drawerSwipe = null;

// Nothing that already owns a sideways gesture may lose it to the drawer, and a
// finger that starts inside a field or behind a dialog is not asking for a
// panel at all.
function drawerSwipeBlocked(target) {
  if (!(target instanceof Element)) return true;
  if (document.querySelector("dialog[open]")) return true;
  if (target.closest("input, textarea, select, [contenteditable='true']")) return true;

  // The roster lies sideways across the top of the drawer; that travel is the
  // roster's own. Anything that already scrolls sideways keeps its gesture too,
  // or a wide code block would open a panel instead of following the finger.
  if (target.closest(".rail")) return true;

  for (let el = target; el && el !== document.body; el = el.parentElement) {
    if (el.scrollWidth <= el.clientWidth + 2) continue;
    const overflow = getComputedStyle(el).overflowX;
    if (overflow === "auto" || overflow === "scroll") return true;
  }
  return false;
}

function drawerSwipeStart(event) {
  drawerSwipe = null;
  if (!window.matchMedia(DRAWER_QUERY).matches) return;
  if (event.touches.length !== 1) return;
  if (drawerSwipeBlocked(event.target)) return;

  const touch = event.touches[0];
  drawerSwipe = { x: touch.clientX, y: touch.clientY, id: touch.identifier };
}

function drawerSwipeMove(event) {
  if (!drawerSwipe) return;

  const touch = Array.from(event.touches).find((t) => t.identifier === drawerSwipe.id);
  if (!touch) return;

  const dx = touch.clientX - drawerSwipe.x;
  const dy = touch.clientY - drawerSwipe.y;

  // A finger that has mostly travelled down the page is scrolling it, not
  // asking for the drawer; staying out of that is the whole reason for the
  // slope test below as well.
  if (Math.abs(dy) > DRAWER_TRAVEL) {
    drawerSwipe = null;
    return;
  }
  if (Math.abs(dx) < DRAWER_TRAVEL) return;
  if (Math.abs(dx) < Math.abs(dy) * DRAWER_SLOPE) return;

  const open = dx > 0;
  drawerSwipe = null;
  window.dispatchEvent(new CustomEvent("rubot:nav", { detail: { open } }));
}

function drawerSwipeEnd() {
  drawerSwipe = null;
}

// Passive: the drawer decides after the gesture, it never holds the scroll
// back while it is still deciding.
document.addEventListener("touchstart", drawerSwipeStart, { passive: true });
document.addEventListener("touchmove", drawerSwipeMove, { passive: true });
document.addEventListener("touchend", drawerSwipeEnd, { passive: true });
document.addEventListener("touchcancel", drawerSwipeEnd, { passive: true });

document.addEventListener("keydown", (event) => {
  if (!(event.metaKey || event.ctrlKey) || event.key.toLowerCase() !== "k") return;
  if (openSearch()) event.preventDefault();
});

document.addEventListener("click", (event) => {
  const el = event.target;
  if (!(el instanceof Element)) return;

  if (el.closest("[data-search-open]")) {
    openSearch();
  } else if (el.closest("[data-search-close]")) {
    closeSearch();
  }
});

// A dialog that is reopened still holds the last answer, and an answer to a
// query nobody can see any more is a list of strangers. Closing empties it.
document.addEventListener("close", (event) => {
  const el = event.target;
  if (!(el instanceof HTMLDialogElement) || el.id !== "search-dialog") return;

  const input = el.querySelector(".search-input");
  if (input instanceof HTMLInputElement) input.value = "";

  const pane = el.querySelector("#search-results");
  if (pane instanceof Element) {
    pane.innerHTML = '<p class="search-hint">Cari di seluruh percakapan, termasuk yang sudah tidak ada di sidebar.</p>';
  }
}, true);

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

// A quote mark beside a paragraph or a list hands that block to the composer
// as context. The handler is on the document because the thread is rewritten by
// every streamed turn: the marks come and go with the markup, and a listener
// bound to each one would have to be rebound on every swap.
document.addEventListener("click", (event) => {
  if (!(event.target instanceof Element)) return;
  const mark = event.target.closest(".para-quote");
  if (!mark) return;

  const block = mark.closest("[data-quote]");
  const composer = document.querySelector(".composer");
  if (!block || !composer) return;

  const data = Alpine.$data(composer);
  if (data && typeof data.quote === "function") {
    data.quote(block.dataset.quote, blockPreview(block), block.dataset.quoteKind);
  }
});

// A long press on a list item quotes just that item. It is the gesture a thumb
// already knows, and it keeps the list's own mark meaning "the whole list":
// precision without a column of marks over the prose. Touch only — with a mouse
// the list mark is a click away, and there a long press would only fight with
// selecting text.
const LONG_PRESS_MS = 450;
const LONG_PRESS_SLOP = 10;
let pressStart = null;
let pressTimer = null;

function cancelPress() {
  clearTimeout(pressTimer);
  pressTimer = null;
  pressStart = null;
}

// What a block looks like in the chip. A paragraph reads as its own rendered
// text (`innerText`, not `textContent`: a hard break is a `<br>`, which carries
// no text of its own, so the two lines would otherwise arrive glued together).
// A list is read item by item: the wrapper's `innerText` would also pick up the
// "selesai:" a task item keeps for screen readers.
function blockPreview(block) {
  if (!block.classList.contains("para-list")) return block.innerText;
  return Array.from(block.querySelectorAll("li")).map(itemText).join(" · ");
}

// The item's own text, without the nested list that would otherwise ride along
// in the chip, and without the spoken "selesai:" the page adds for a task.
function itemText(item) {
  const clone = item.cloneNode(true);
  clone.querySelectorAll("ul, ol, .sr-only").forEach((node) => node.remove());
  return clone.textContent.replace(/\s+/g, " ").trim();
}

// Which item of its list this is: "Butir 3" says more than the preview alone
// when the quoted line is short.
function itemKind(item) {
  const list = item.parentElement;
  if (!list || (list.tagName !== "UL" && list.tagName !== "OL")) return "Butir";
  return `Butir ${Array.from(list.children).indexOf(item) + 1}`;
}

document.addEventListener("pointerdown", (event) => {
  if (event.pointerType !== "touch" || !(event.target instanceof Element)) return;
  // The list's own mark is a press, not a hold.
  if (event.target.closest(".para-quote")) return;

  const item = event.target.closest(".text li[data-quote]");
  if (!item) return;

  pressStart = { x: event.clientX, y: event.clientY };
  pressTimer = setTimeout(() => {
    cancelPress();
    // The same gesture is how text selection starts, so whatever the browser
    // grabbed on the way is dropped: the press was meant as a quote.
    const selection = window.getSelection();
    if (selection) selection.removeAllRanges();

    const composer = document.querySelector(".composer");
    const data = composer && Alpine.$data(composer);
    if (data && typeof data.quote === "function") {
      data.quote(item.dataset.quote, itemText(item), itemKind(item));
    }
  }, LONG_PRESS_MS);
});

document.addEventListener("pointermove", (event) => {
  if (!pressTimer || !pressStart) return;
  if (Math.abs(event.clientX - pressStart.x) > LONG_PRESS_SLOP ||
      Math.abs(event.clientY - pressStart.y) > LONG_PRESS_SLOP) {
    cancelPress();
  }
});

document.addEventListener("pointerup", cancelPress);
document.addEventListener("pointercancel", cancelPress);

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

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------
//
// The button in the drawer asks this device to be woken when something happens
// while the app is closed — a reminder fired, a scheduled turn finished. The
// permission is only ever requested from a press: a prompt that arrives on its
// own is the one readers learn to dismiss, and iOS ignores the request entirely
// unless a tap is what asked.
//
// Nothing here polls. The button reads the current state once and otherwise
// speaks only when it is pressed.

const PUSH_SUPPORTED = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
// Push only exists in a secure context, and an origin reached over plain HTTP
// has no way to offer it. Saying so is kinder than a button that fails on every
// press — Tailscale and mkcert both get you the certificate this needs.
const PUSH_SECURE = window.isSecureContext ||
  ["localhost", "127.0.0.1", "::1"].includes(window.location.hostname);
const PUSH_LABELS = {
  loading: "memuat…",
  off: "aktifkan",
  on: "aktif",
  denied: "diblokir",
  https: "butuh https",
  unsupported: "tidak didukung",
  busy: "sebentar…",
  failed: "coba lagi"
};

// A P-256 point in the base64url the server sends, as the bytes the browser
// API wants. `atob` is fine here: a key is 65 bytes, not a file.
function pushKeyBytes(value) {
  const padded = (value + "=".repeat((4 - (value.length % 4)) % 4)).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(padded);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i += 1) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

async function pushRegistration() {
  // `ready` waits for an active worker; if the worker failed to install it
  // waits forever, which on the drawer would look like a button stuck on
  // "memuat". A timeout turns that into an honest "tidak didukung".
  return Promise.race([
    navigator.serviceWorker.ready,
    new Promise((_resolve, reject) => setTimeout(() => reject(new Error("no worker")), 4000))
  ]);
}

async function pushPost(path, fields) {
  const response = await fetch(path, {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(fields)
  });
  if (!response.ok) throw new Error(`push: ${path} ${response.status}`);
  return response.json().catch(() => ({}));
}

async function pushSubscriptionFields(subscription) {
  const json = subscription.toJSON();
  return {
    endpoint: subscription.endpoint,
    p256dh: json.keys.p256dh,
    auth: json.keys.auth
  };
}

// This script is loaded from <head> without `defer`, so it runs while the body
// is still being parsed: the drawer does not exist yet, and a lookup here would
// quietly find nothing and leave the button saying "memuat…" forever. The
// control is wired once the markup is there.
function initPush() {
  const picker = document.querySelector("[data-push-slug]");
  const toggle = document.querySelector("[data-push-toggle]");
  const test = document.querySelector("[data-push-test]");
  const label = document.querySelector("[data-push-label]");
  if (!picker || !label) return;

  if (!PUSH_SUPPORTED) {
    // A browser without the Push API gets a word about it rather than a label
    // stuck on "memuat…" — the same honesty the other states carry.
    picker.dataset.pushState = "unsupported";
    label.textContent = PUSH_LABELS.unsupported;
    return;
  }

  if (picker && toggle && label) {
    const slug = picker.dataset.pushSlug || "";

    const setState = (state) => {
      picker.dataset.pushState = state;
      toggle.setAttribute("aria-pressed", state === "on" ? "true" : "false");
      toggle.disabled = state === "unsupported" || state === "https";
      label.textContent = PUSH_LABELS[state] || state;
      if (test) test.hidden = state !== "on";
    };

    // The label is the state, so a press that is still working has to say so
    // instead of leaving the old word in place under a spinner-less button.
    const refresh = async () => {
      if (!PUSH_SECURE) {
        setState("https");
        return;
      }

      if (Notification.permission === "denied") {
        setState("denied");
        return;
      }

      try {
        const registration = await pushRegistration();
        const subscription = await registration.pushManager.getSubscription();
        setState(subscription ? "on" : "off");
      } catch (_error) {
        // No worker, no subscription: the permission may be granted and there
        // is still nowhere to deliver, so the control offers to try again.
        setState("off");
      }
    };

    const enable = async () => {
      const permission = await Notification.requestPermission();
      if (permission !== "granted") {
        setState(permission === "denied" ? "denied" : "off");
        return;
      }

      const response = await fetch("/push/key", {
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      });
      if (!response.ok) throw new Error("push key unavailable");
      const { key } = await response.json();

      const registration = await pushRegistration();
      // A device that subscribed before keeps its subscription; asking again is
      // only necessary when there is nothing to reuse.
      const existing = await registration.pushManager.getSubscription();
      const subscription = existing || await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: pushKeyBytes(key)
      });

      await pushPost("/push/subscribe", await pushSubscriptionFields(subscription));
      setState("on");
    };

    const disable = async () => {
      const registration = await pushRegistration();
      const subscription = await registration.pushManager.getSubscription();
      if (subscription) {
        await pushPost("/push/unsubscribe", { endpoint: subscription.endpoint });
        await subscription.unsubscribe();
      }
      setState("off");
    };

    toggle.addEventListener("click", async () => {
      if (toggle.disabled) return;
      const wasOn = toggle.getAttribute("aria-pressed") === "true";
      setState("busy");

      try {
        if (wasOn) await disable();
        else await enable();
      } catch (_error) {
        setState("failed");
      }
    });

    if (test) {
      // One press, one message, then back to the button's own words. The
      // message is cleared here rather than in each branch so a "shown" answer
      // arriving from the worker can replace "terkirim" without two timers
      // racing over the same label.
      const rest = test.textContent;
      let testTimer = null;
      const say = (text) => {
        test.textContent = text;
        clearTimeout(testTimer);
        testTimer = setTimeout(() => {
          test.textContent = rest;
          test.disabled = false;
        }, 4000);
      };

      test.addEventListener("click", async () => {
        test.disabled = true;
        test.textContent = "mengirim…";
        try {
          const result = await pushPost("/push/test", { persona: slug });
          // The push service's own answer is worth showing: 201 means it took
          // the message, and anything else is the reason it did not.
          const code = (result.status && result.status[0]) || "";
          say(result.sent > 0 ? `terkirim ${code}`.trim() : "tidak terkirim");
        } catch (_error) {
          say("gagal");
        }
      });

      if ("serviceWorker" in navigator) {
        // The worker reports that the notification actually reached the screen,
        // which is the one thing a server cannot know.
        navigator.serviceWorker.addEventListener("message", (event) => {
          if (event.data && event.data.type === "rubot-push-shown") say("ditampilkan");
        });
      }
    }

    refresh();
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initPush, { once: true });
} else {
  initPush();
}
