// Alpine glue for the chat shell. Everything that renders HTML lives on the
// Ruby side; this file only wires the composer and keeps the active-turn
// marker in sync with the SSE connection.
document.addEventListener("alpine:init", () => {
  // `stopping` lives here, not in the composer, because it is a fact about the
  // turn: the request to stop is made against a turn, and the word "Membatalkan…"
  // stays true only while that turn is still running. Keeping it in the
  // component meant it had to be cleared by whoever finished the round trip,
  // which is the wrong moment — the server answers "queued" long before the
  // work actually stops.
  // `compacting` is separate from `active`: a manual compaction runs while the
  // page is idle, with no turn to own the session, but the composer must still
  // refuse a prompt until the summarizer is done. Keeping it in the store lets
  // the htmx listeners below set it without reaching into a component.
  Alpine.store("turn", { active: null, stopping: false, compacting: false });

  Alpine.data("composer", () => ({
    text: "",
    // Paragraphs taken from the conversation with the quote mark beside them.
    // Each one rides above the field as a chip and is stitched into the
    // message when it is sent, so the field itself only ever holds what the
    // reader typed.
    quotes: [],
    quoteSeq: 0,
    // Read from the turn store: set the moment the button is pressed to stop,
    // cleared when the turn it was pressed against is over. The turn stays live
    // during the round trip and after the server has answered, so the button
    // has to keep saying what is actually happening — without this it looked
    // untouched, and a second press simply repeated the request.
    get stopping() {
      return Alpine.store("turn").stopping;
    },

    get busy() {
      return Alpine.store("turn").active !== null;
    },

    get compacting() {
      return Alpine.store("turn").compacting;
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

      // Half a thought typed into this session comes back when the reader
      // returns to it. Opening another conversation is a page load, so the
      // field would otherwise be empty again and the sentence lost — the one
      // thing a reader cannot undo.
      this.text = readDraft(this.draftId);
      this.$watch("text", (value) => writeDraft(this.draftId, value));
    },

    get draftId() {
      return (this.$el && this.$el.dataset.draft) || "";
    },

    keydown(event) {
      if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
      if (this.touchOnly) return;
      event.preventDefault();
      this.send();
    },

    send() {
      const text = this.text.trim();
      if (!text || this.stopping || this.compacting) return;

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
    // for as long as the turn lives; the stream closing is what ends that, and
    // it is also what takes the button out of the page again.
    async stop() {
      const store = Alpine.store("turn");
      const active = store.active;
      if (!active || store.stopping) return;

      store.stopping = true;
      try {
        const response = await fetch(`/turns/${active}/stop`, { method: "POST" });
        // A refused request means the turn is still running exactly as before,
        // so the button must not stay stuck on a label that is no longer true.
        if (!response.ok) store.stopping = false;
      } catch (_error) {
        store.stopping = false;
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

// Drafts are kept per conversation and per tab. Per conversation because a
// prompt typed in one is not a prompt for another — carrying it across would
// put words in the reader's mouth in the wrong place. Per tab because a draft
// is a thing being written right now: it belongs to the window it is in, and
// outliving the tab would mean the next visit starts with someone else's
// half-finished sentence in the field.
const DRAFT_KEY = "rubot:draft:";

function readDraft(id) {
  if (!id) return "";
  try {
    return window.sessionStorage.getItem(DRAFT_KEY + id) || "";
  } catch (_error) {
    // Storage that throws (private modes, a full quota) is not a reason to
    // lose the field: the composer simply starts empty, as it did before.
    return "";
  }
}

function writeDraft(id, text) {
  if (!id) return;
  try {
    // An empty field is the absence of a draft, not an empty string: keeping
    // the key would leave one row per conversation ever visited.
    if (text) window.sessionStorage.setItem(DRAFT_KEY + id, text);
    else window.sessionStorage.removeItem(DRAFT_KEY + id);
  } catch (_error) {}
}
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

// The model and thinking choice is refused while a turn owns the session
// (409). htmx leaves the element alone on an error, which would leave the
// dialog showing a choice the session never took — so the choice goes back to
// the values the server last rendered, and the dialog closes, because nothing
// was applied.
document.addEventListener("htmx:responseError", (event) => {
  const form = event.detail.elt;
  if (!(form instanceof Element) || !form.matches("#session-settings")) return;

  resetSettingsChoices(form);
  closeSettings();
});

// A later accepted prompt clears that notice: it described a moment that has
// passed, and leaving it under the field would read as a standing warning.
// A manual compaction runs while the page is idle, so there is no live turn to
// make the composer busy. The button owns the whole round trip, from the press
// until the page reloads with the seam; hold the composer closed for that span
// so a prompt cannot be sent against a transcript that is being rewritten.
document.addEventListener("htmx:beforeRequest", (event) => {
  const el = event.detail.elt;
  if (!(el instanceof Element) || !el.classList.contains("compact-toggle")) return;
  Alpine.store("turn").compacting = true;
});

document.addEventListener("htmx:afterRequest", (event) => {
  const el = event.detail.elt;
  if (!(el instanceof Element) || !el.classList.contains("compact-toggle")) return;
  // A 204 means the compaction was accepted and is running in the background;
  // keep the composer closed until the reload event arrives. A refusal (a turn
  // started in the meantime) answers with markup instead, and the reader stays
  // on this page, so they must be able to type again.
  if (event.detail.xhr && event.detail.xhr.status === 204) return;
  Alpine.store("turn").compacting = false;
});

// The background compaction cannot send HX-Refresh from a request that already
// answered, so it signals the reload over the always-on /events stream. The
// slot in index.erb makes htmx surface it here; the reload redraws the seam
// from the saved transcript and resets the composer's compacting flag.
document.addEventListener("htmx:sseMessage", (event) => {
  // htmx passes the native MessageEvent as detail. Its `type` is always
  // "message", not the SSE event name, and its `elt` slot can be replaced by
  // an earlier out-of-band swap. The payload is the one thing that cannot be
  // taken away, so the signals are carried in `data` itself.
  if (!event.detail) return;
  if (event.detail.data === "reload") window.location.reload();
  // An empty or failed compaction leaves the page in place, so release the
  // composer here instead of waiting for a reload that will never come.
  if (event.detail.data === "done") Alpine.store("turn").compacting = false;
});



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
  const store = Alpine.store("turn");
  store.active = null;
  // A stop that was asked for is answered by the turn being gone; the next one
  // starts with the button back to its plain word.
  store.stopping = false;

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

// The page's idle stream is what carries a manual compaction's ending. If that
// stream closes, the composer would hold the compacting flag for a message that
// is no longer coming, and the button would look dead. Release it here; the
// server refuses a prompt while the summarizer really runs, so a wrong guess
// costs a note, not a transcript caught mid-rewrite.
document.addEventListener("htmx:sseClose", (event) => {
  const elt = event.detail && event.detail.elt;
  if (!(elt instanceof Element)) return;
  if (!elt.closest(".session-events")) return;

  Alpine.store("turn").compacting = false;
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

// Following is for the turn the reader is watching: the block that grows under
// their eyes. Everything else that lands on this page — a footer figure, the
// roster, a report appended from the background — is not that, and scrolling
// for any of them moved the answer being read upward whenever one arrived.
const FOLLOW_ONLY_INSIDE = ".turn-body";
const REPORT_BLOCK = ".turn.is-report";

function isFollowedContent(el) {
  if (!(el instanceof Element)) return false;
  if (el.closest(REPORT_BLOCK)) return false;
  return el.closest(FOLLOW_ONLY_INSIDE) !== null;
}

function followTurn(target = null) {
  const thread = threadEl();
  if (!thread || thread.dataset.pinned !== "true") return;
  // An event that says nothing about the turn's own text (the footer, the
  // roster, the report) must not decide where the thread is scrolled.
  if (target && !isFollowedContent(target)) return;
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
// thread grows under it. Following is the default only from the end, and only
// for the turn itself: the slot the event arrived at says which it is.
document.addEventListener("htmx:sseMessage", (event) => followTurn(event.target));

document.addEventListener("htmx:afterSwap", (event) => {
  // The target says what changed: a turn's own body is followed, an append into
  // the thread or a footer figure is not (see `isFollowedContent`).
  followTurn(event.detail.elt);
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
  const thread = threadEl();
  if (!thread) return;
  if (landOnSearchHit()) return;

  jumpToBottom();
  // A conversation whose first page does not fill the screen has nothing to
  // scroll, so no scroll event would ever ask for the page above. Ask once here
  // instead: a short page then fills itself the same way a long one does.
  askForOlderPage(thread);
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
// The model and thinking dialog
// ---------------------------------------------------------------------------
//
// The two per-session choices in one place, opened from the caption under the
// composer. The model half is a list long enough to need a field that searches
// it; the effort half is four words under it. Both are radios in the same form,
// so one save carries both and the server can never receive half a change.
//
// The dialog edits a copy: the choice it shows is the one the server last
// rendered, so reopening after a change that was never saved — or one it refused
// — starts from the truth rather than from the last thing a finger touched.
function settingsForm() {
  const form = document.getElementById("session-settings");
  return form instanceof HTMLElement ? form : null;
}

function settingsDialog() {
  const dialog = document.getElementById("session-settings-dialog");
  return dialog instanceof HTMLDialogElement ? dialog : null;
}

function resetSettingsChoices(form = settingsForm()) {
  if (!form) return;

  form.querySelectorAll('input[type="radio"]').forEach((input) => {
    input.checked = input.value === (form.dataset[input.name] || "");
  });
}

// The query narrows the list in place. Rows carry what they can be found by —
// label and id both — so searching "glm" and searching "zhipu" reach the same
// model.
function filterModels(query) {
  const list = document.querySelector("[data-model-list]");
  if (!list) return;

  const needle = query.trim().toLowerCase();
  let shown = 0;
  let total = 0;

  list.querySelectorAll(".model-choice").forEach((row) => {
    total += 1;
    const hit = !needle || (row.dataset.search || "").includes(needle);
    row.hidden = !hit;
    if (hit) shown += 1;
  });

  const empty = document.querySelector("[data-model-empty]");
  if (empty) empty.hidden = shown !== 0;

  const count = document.querySelector("[data-model-count]");
  if (count) count.textContent = needle ? `${shown}/${total} model` : `${total} model`;
}

function openSettings() {
  const dialog = settingsDialog();
  if (!dialog) return;

  resetSettingsChoices();

  const search = dialog.querySelector("[data-model-search]");
  if (search instanceof HTMLInputElement) search.value = "";
  filterModels("");

  if (!dialog.open) dialog.showModal();
  if (search instanceof HTMLInputElement) search.focus();
}

function closeSettings() {
  const dialog = settingsDialog();
  if (dialog instanceof HTMLDialogElement && dialog.open) dialog.close();
}

document.addEventListener("click", (event) => {
  const target = event.target;
  if (!(target instanceof Element)) return;

  if (target.closest("[data-settings-open]")) {
    openSettings();
    return;
  }

  if (target.closest("[data-settings-close]")) closeSettings();
});

document.addEventListener("input", (event) => {
  const target = event.target;
  if (!(target instanceof Element) || !target.matches("[data-model-search]")) return;

  filterModels(target.value);
});

// Enter in the field picks the first model still shown instead of submitting:
// the field is where a model is found, and saving belongs to the button. Without
// this, typing a query and pressing enter would save whatever was checked
// before the search.
document.addEventListener("keydown", (event) => {
  const target = event.target;
  if (!(target instanceof Element) || !target.matches("[data-model-search]")) return;
  if (event.key !== "Enter") return;

  event.preventDefault();

  const first = document.querySelector("[data-model-list] .model-choice:not([hidden]) input");
  if (first instanceof HTMLInputElement) first.checked = true;
});

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
//
// "Near the top" is only a request to go back if the reader went back. A short
// thread sits within the lead while resting at its end, and a turn streaming in
// would otherwise pull a page nobody asked for — the fill is the one place a
// page is fetched without an upward scroll.
//
// A falling `scrollTop` is not always a gesture: the keyboard opening shrinks the
// shell, and a browser clamps a scroll offset down when its content shrinks, both
// of which look exactly like the reader moving up. Only a scroll that leaves the
// box alone is a gesture, so the box is what is compared along with the offset.
let lastThreadScroll = 0;
let lastThreadBox = "";

document.addEventListener(
  "scroll",
  (event) => {
    const el = event.target;
    if (!(el instanceof Element) || el.id !== "thread") return;

    const box = `${el.clientHeight}x${el.scrollHeight}`;
    const layoutMoved = box !== lastThreadBox;
    const wentBack = !layoutMoved && el.scrollTop < lastThreadScroll;
    lastThreadBox = box;
    lastThreadScroll = el.scrollTop;

    noteThreadPosition(el);
    if (wentBack) askForOlderPage(el, true);
  },
  { capture: true, passive: true }
);

// Prepending a page moves everything below it down, which would slide the
// conversation out from under the reader mid-scroll. What is preserved is the
// distance from the bottom: content added above the viewport cannot change it,
// so the reader stays on the sentence they were reading.
//
// htmx cannot carry this page. Its `revealed` trigger re-checks a sentinel only
// on a *window* scroll, and this shell never scrolls the window — `#thread` is
// the scroll container, on purpose (see `html, body` in app.css). The sentinel
// therefore sat at the top of the thread and never asked for anything, which is
// why scrolling up produced no older page at all.
//
// So the scroll that matters is read here instead: once the reader is within
// HISTORY_LEAD of the top, the page above is fetched and prepended in the
// sentinel's place, and the distance from the bottom is put back.
const HISTORY_LEAD = 700; // px from the top at which the next page is asked for
let olderPageInFlight = false;
// When a page may be asked for again after a failure. One refusal is not a
// reason to hammer the server on every upward gesture, and it is not a reason to
// give up either: a token gate can be unlocked in another tab, and the same URL
// then answers normally.
let olderPageRetryAt = 0;

function askForOlderPage(thread, movingUp = false) {
  if (olderPageInFlight || Date.now() < olderPageRetryAt) return;
  // Two ways to earn a page: the reader moved the thread up, or the thread has
  // nothing to scroll at all and would otherwise strand the sentinel below the
  // fold with no gesture that could ever reach it. A thread that is merely
  // short — the end of the conversation sits 200px from the top — is neither:
  // its scrollTop is inside the lead, and asking on any touch there would pull
  // pages the reader never asked for.
  const scrollable = thread.scrollHeight > thread.clientHeight + 1;
  if (!movingUp && scrollable) return;
  if (thread.scrollTop > HISTORY_LEAD) return;
  const sentinel = thread.querySelector(":scope > .history-more");
  if (!sentinel) return;

  const url = sentinel.dataset.historyUrl;
  if (!url) return;

  olderPageInFlight = true;

  fetch(url, {
    headers: { "HX-Request": "true" },
    credentials: "same-origin",
    // An older browser without this throws here, before any handler exists: the
    // flag above would stay set and the thread would never page again.
    signal: typeof AbortSignal !== "undefined" && AbortSignal.timeout
      ? AbortSignal.timeout(15000)
      : undefined
  })
    .then((response) => {
      if (!response.ok) {
        // A deleted session will not come back. Everything else might: the token
        // gate answers 403 until the reader unlocks it, and a restarted or
        // throttled server answers 5xx for a while. Those keep the sentinel and
        // wait, so a page that is still there is not lost for good.
        if ([ 404, 410 ].includes(response.status)) sentinel.remove();
        olderPageRetryAt = Date.now() + 5000;
        console.warn("[history] page refused:", response.status, url);
        throw new Error(String(response.status));
      }
      return response.text();
    })
    .then((html) => {
      // The gap is read now, not before the request: a turn streaming into the
      // bottom of the thread during the round trip changes the height, and a
      // number sampled before it would shove the reader by exactly that much.
      const gap = thread.scrollHeight - thread.scrollTop;
      const previous = sentinel.previousElementSibling;
      sentinel.insertAdjacentHTML("beforebegin", html);
      const added = [];
      for (let node = sentinel.previousElementSibling; node && node !== previous; node = node.previousElementSibling) {
        added.push(node);
      }
      sentinel.remove();
      thread.scrollTop = thread.scrollHeight - gap;
      noteThreadPosition(thread);

      // A block whose height is only known after layout (a paragraph that
      // reflows, an image that decodes) is left to the browser: Chromium and
      // Firefox keep the reader's anchor when content above them grows, and a
      // hand-written second correction would fight it — and would drag the
      // reader down when the growth was below them. Safari has no scroll
      // anchoring, so there a tall image inside a fetched page can still move
      // the view once; that is the residue of not owning the offset twice.

      // htmx has not seen this markup. A replayed connect card carries its own
      // hx-post, and without this its buttons fall back to a full page
      // navigation — into a thread that no longer exists. Only the nodes just
      // added are handed over: processing the whole thread would re-hash every
      // row of the conversation for nothing. Each node is its own try, so one
      // bad fragment does not leave the rest of the page inert.
      added.reverse().forEach((node) => {
        try {
          if (typeof htmx !== "undefined" && htmx.process) htmx.process(node);
        } catch (error) {
          console.warn("[history] page inserted but not processed:", error);
        }
      });
    })
    .catch((error) => {
      // A page that never arrives must not strand the reader: unless it was
      // retired above, the sentinel is still there and the next scroll asks
      // again, once the cooldown has passed.
      console.warn("[history] no older page:", error.message);
    })
    .finally(() => {
      olderPageInFlight = false;
      // A page that still leaves nothing to scroll has no gesture left to ask
      // with, so it asks here instead. Bounded by the pages that exist and by
      // the cooldown above.
      if (thread.scrollHeight <= thread.clientHeight + 1) askForOlderPage(thread, movingUp);
    });
}

// A page restored from the back/forward cache comes back exactly where it was
// left, and a thread restored at the very top emits no scroll event at all — so
// the page above it would be unreachable for the rest of that page's life. The
// baseline is taken again here, and the fill is asked for on the reader's
// behalf: what was below them before they left is not a gesture now.
window.addEventListener("pageshow", () => {
  const thread = threadEl();
  if (!thread) return;

  lastThreadScroll = thread.scrollTop;
  lastThreadBox = `${thread.clientHeight}x${thread.scrollHeight}`;
  askForOlderPage(thread, true);
});

// Compact tool call: crossfade the turn body only when the call row changes
// identity, so a new call fades in (and the previous one fades out) instead of
// popping. Doing it on every stream tick would fade the whole timeline twenty
// times a second, so the swap is left alone unless the tool key moved.
document.addEventListener("htmx:beforeSwap", (event) => {
  const target = event.detail && event.detail.target;
  if (!(target instanceof Element) || !target.classList.contains("turn-body")) return;
  // The row that matters is the newest one — the call in flight is the last row
  // of the timeline, and every earlier call is history. Reading the first one
  // froze the comparison at a row that no longer changes, so a row that stayed
  // at the top (a skill load never collapses in compact mode) kept the swap
  // from ever fading.
  const rows = target.querySelectorAll(".tool-row");
  const currentKey = rows.length ? rows[rows.length - 1].dataset.toolKey || "" : "";
  const incoming = String((event.detail && event.detail.serverResponse) || "");
  const matches = incoming.matchAll(/data-tool-key="([^"]*)"/g);
  let incomingKey = "";
  for (const match of matches) incomingKey = match[1];
  if (currentKey && incomingKey && currentKey !== incomingKey) {
    event.detail.swapOverride = "innerHTML transition:true";
  } else {
    event.detail.swapOverride = "innerHTML transition:false";
  }
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

// A turn redraws its whole timeline on every event, so the call row is a new
// node each time — and a CSS animation on it would restart with every stream
// tick, which reads as a flicker rather than a transition. What is worth
// marking is the one moment the row changes *identity*: one call replacing
// ---------------------------------------------------------------------------
// Lightbox
// ---------------------------------------------------------------------------
//
// Any picture or video in the thread can be opened full size. The handler is
// on the document rather than on each card because the thread is written by
// the server and swapped in pieces: a listener bound at load time would go
// stale on the first turn, while a delegated one keeps working for every file
// that has ever arrived — including the ones an answer brings.
function openLightbox(url, name, kind) {
  const box = document.getElementById("lightbox");
  if (!box) return;

  const image = box.querySelector(".lightbox-image");
  const video = box.querySelector(".lightbox-video");
  const link = box.querySelector(".lightbox-download");
  if (!image || !video || !link) return;

  const isVideo = kind === "video";
  // Only one of the two media is shown. The other is emptied so a closed
  // sheet holds no decoded picture and no video still playing in the background.
  video.pause();
  video.removeAttribute("src");
  video.hidden = !isVideo;
  image.hidden = isVideo;
  image.removeAttribute("src");
  if (isVideo) {
    video.src = url;
  } else {
    image.src = url;
    image.alt = name || "";
  }
  link.href = url;
  link.download = name || "";

  box.hidden = false;
  box.classList.add("is-open");
  // The page behind must not scroll under the sheet.
  document.body.classList.add("lightbox-open");
  const close = box.querySelector(".lightbox-close");
  if (close) close.focus();
  if (isVideo) video.play().catch(() => {});
}

function closeLightbox() {
  const box = document.getElementById("lightbox");
  if (!box || box.hidden) return;

  box.hidden = true;
  box.classList.remove("is-open");
  document.body.classList.remove("lightbox-open");

  // Drop both sources so a closed sheet holds no decoded image and no video
  // still playing out of sight.
  const image = box.querySelector(".lightbox-image");
  const video = box.querySelector(".lightbox-video");
  if (video) {
    video.pause();
    video.removeAttribute("src");
  }
  if (image) image.removeAttribute("src");
}

document.addEventListener("click", (event) => {
  const trigger = event.target.closest("[data-lightbox]");
  if (trigger) {
    event.preventDefault();
    openLightbox(trigger.dataset.lightbox, trigger.dataset.name, trigger.dataset.lightboxKind);
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
// Status row panels
// ---------------------------------------------------------------------------
//
// The row at the bottom edge carries two `<details>` panels — what the figures
// are made of, and how much allowance is left — and both hang upward out of the
// same spot. Two of them open at once would be one panel on top of another, so
// opening either closes the other. Escape closes whichever is open: they are
// not dialogs and dim nothing, so the key has to be wired rather than inherited.
const STATUS_PANELS = ".status-line details.usage-sheet[open]";

function closeStatusPanels(except) {
  document.querySelectorAll(STATUS_PANELS).forEach((panel) => {
    if (panel !== except) panel.open = false;
  });
}

// `toggle` does not bubble, so it is caught on the way down.
document.addEventListener("toggle", (event) => {
  const panel = event.target;
  if (panel.classList?.contains("usage-sheet") && panel.open) closeStatusPanels(panel);
}, true);

// Clicking outside an open panel closes it: the panels dim nothing, so a
// reader who taps elsewhere expects the sheet to fold back up.
document.addEventListener("click", (event) => {
  document.querySelectorAll(STATUS_PANELS).forEach((panel) => {
    if (!panel.contains(event.target)) panel.open = false;
  });
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") closeStatusPanels(null);
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

// The marks are painted from the attributes on <html>, so they can only be
// drawn once the buttons exist — and this file is read in <head>, before there
// is a body. `DOMContentLoaded` is that moment; `htmx:afterSwap` is every later
// one, because a swap can bring a fresh set of buttons with it.
function syncAppearance() {
  applyTheme(currentTheme());
  applyFont(currentFont());
}

document.addEventListener("htmx:afterSwap", syncAppearance);
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", syncAppearance);
} else {
  syncAppearance();
}

// The attributes themselves are already right (the head script wrote them), but
// the address bar's colour comes from a meta that only this can repaint.
applyTheme(currentTheme());

// ---------------------------------------------------------------------------
// Reading face
// ---------------------------------------------------------------------------
//
// The same contract as the theme, one control further in: the head script has
// already put the saved face on <html> before the first paint, and this keeps
// the buttons marked and records a change.
//
// The stacks live in app.css as one block per value, so a name in this list
// without a block there would do nothing — the two have to stay in step, and
// the list is also what the settings page draws its buttons from. A value that
// no longer means anything (an older install, a hand-edited key) falls back to
// the serif rather than leaving the page in a browser default.
const FONT_KEY = "rubot-font";
const FONTS = ["serif", "sans", "mono", "georgia", "palatino"];

function applyFont(name) {
  const font = FONTS.includes(name) ? name : "serif";
  document.documentElement.setAttribute("data-font", font);

  document.querySelectorAll("[data-font-choice]").forEach((button) => {
    button.setAttribute("aria-pressed", button.dataset.fontChoice === font ? "true" : "false");
  });
}

function currentFont() {
  return document.documentElement.getAttribute("data-font") || "serif";
}

document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-font-choice]");
  if (!button) return;

  const font = button.dataset.fontChoice;
  try { localStorage.setItem(FONT_KEY, font); } catch (_error) { /* private mode */ }
  applyFont(font);
});

// ---------------------------------------------------------------------------
// Settings tabs
// ---------------------------------------------------------------------------
//
// The settings page is one form with five subjects. As tabs, the page shows one
// subject at a time and the single Save button still posts all of them: a panel
// that is `display: none` still contributes its fields to the FormData, which
// is what stops a save made from the Instagram tab from dropping the model the
// reader changed a minute earlier.
//
// The markup already marks the first panel, and that is also the page with no
// script: every panel shows, in full, with no strip. This only decides which
// one is on — last visit's, then the address's, then the first.
//
// `sessionStorage`, not `localStorage`: which tab a reader was on is a fact
// about one sitting, and the reload after Save is the moment it has to survive.
const SETTINGS_TAB_KEY = "rubot-settings-tab";

function settingsTabs() {
  const root = document.querySelector("[data-settings-tabs]");
  const strip = root && root.querySelector('[role="tablist"]');
  if (!root || !strip) return;

  const tabs = Array.from(strip.querySelectorAll("[data-settings-tab]"));
  if (!tabs.length) return;

  const show = (name, remember) => {
    const target = tabs.find((tab) => tab.dataset.settingsTab === name) || tabs[0];

    tabs.forEach((tab) => {
      const on = tab === target;
      tab.setAttribute("aria-selected", on ? "true" : "false");
      tab.tabIndex = on ? 0 : -1;
      const panel = document.getElementById(tab.getAttribute("aria-controls"));
      if (panel) panel.classList.toggle("is-active", on);
    });

    if (remember) {
      try { sessionStorage.setItem(SETTINGS_TAB_KEY, target.dataset.settingsTab); } catch (_error) { /* private mode */ }
    }
    // The address carries it too, so a reload or a back button lands on the
    // panel that was open rather than on the first one.
    if (window.history && window.history.replaceState) {
      window.history.replaceState(null, "", `#${target.dataset.settingsTab}`);
    }
  };

  strip.addEventListener("click", (event) => {
    const tab = event.target.closest("[data-settings-tab]");
    if (tab) show(tab.dataset.settingsTab, true);
  });

  // One stop in the tab order, and the arrows move between the tabs inside it:
  // that is what makes the strip a control rather than five buttons that happen
  // to sit in a row.
  strip.addEventListener("keydown", (event) => {
    const current = event.target.closest("[data-settings-tab]");
    if (!current) return;

    const index = tabs.indexOf(current);
    let next = null;
    if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
    else if (event.key === "ArrowLeft") next = (index - 1 + tabs.length) % tabs.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = tabs.length - 1;
    if (next === null) return;

    event.preventDefault();
    tabs[next].focus();
    show(tabs[next].dataset.settingsTab, true);
  });

  let remembered = "";
  try { remembered = sessionStorage.getItem(SETTINGS_TAB_KEY) || ""; } catch (_error) { /* private mode */ }
  const named = (window.location.hash || "").replace("#", "");

  show(named || remembered || tabs[0].dataset.settingsTab, false);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", settingsTabs, { once: true });
} else {
  settingsTabs();
}

// ---------------------------------------------------------------------------
// Emoji picker
// ---------------------------------------------------------------------------
//
// The face a persona wears is one picture, so the field is one button showing
// it rather than a grid of forty cells that pushes the rest of the form off the
// panel. The roster behind the button is every emoji Unicode ships — a few
// thousand cells, far too much to send with the page — so it arrives as its own
// script the first time a picker is opened, and the browser keeps it from then
// on. Before it lands the panel shows the short roster the server drew.
//
// Nothing here is wired per element: the panels are swapped by htmx and can be
// several at once, so every handler is delegated and reads the state of the
// picker it was clicked in.
const EMOJI_DATA_URL = "/assets/emoji.js";
// A view is capped rather than paginated: the search field is right above it,
// so "too many to show" is answered by typing, not by scrolling deeper.
const EMOJI_MAX_CELLS = 320;
const emojiPickers = new WeakMap();

let emojiDataPromise = null;

function loadEmojiData() {
  if (window.RUBOT_EMOJI) return Promise.resolve(window.RUBOT_EMOJI);

  if (!emojiDataPromise) {
    emojiDataPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = EMOJI_DATA_URL;
      script.async = true;
      script.onload = () => {
        if (window.RUBOT_EMOJI) resolve(window.RUBOT_EMOJI);
        else reject(new Error("no emoji data"));
      };
      script.onerror = () => reject(new Error("could not load emoji data"));
      document.head.appendChild(script);
    });

    // A failed load is not worth remembering: the next open tries again.
    emojiDataPromise.catch(() => { emojiDataPromise = null; });
  }

  return emojiDataPromise;
}

// Each entry is a picture followed by its name — "🚀 rocket" — so the space is
// what separates them; a picture never contains one.
function parseEmojiData(raw) {
  const groups = (raw.groups || []).map(([name, entries]) => ({
    name,
    entries: entries.map((entry) => {
      const cut = entry.indexOf(" ");
      return cut < 0
        ? { char: entry, words: "" }
        : { char: entry.slice(0, cut), words: entry.slice(cut + 1) };
    }),
  }));
  const all = groups.flatMap((group) => group.entries);
  const byChar = new Map(all.map((entry) => [entry.char, entry]));

  return { groups, all, byChar };
}

function emojiPickerState(root) {
  let state = emojiPickers.get(root);
  if (!state) {
    state = { group: null, query: "", data: null, loading: false, failed: false };
    emojiPickers.set(root, state);
  }
  return state;
}

function shortGroupName(name) {
  return String(name).split(" ")[0];
}

function emojiCells(list, selected) {
  return list.map((entry) => {
    const title = entry.words ? `${entry.char} ${entry.words}` : entry.char;
    const pick = entry.char === selected ? "true" : "false";
    return `<button type="button" class="emoji-cell" data-emoji-cell="${entry.char}"` +
      ` aria-selected="${pick}" title="${title}">${entry.char}</button>`;
  }).join("");
}

function emojiChips(state) {
  const first = `<button type="button" class="emoji-group" data-emoji-group="-1"` +
    ` aria-pressed="${state.group === null && !state.query}">Sering</button>`;
  if (!state.data) return first;

  return first + state.data.groups.map((group, index) => {
    const active = state.group === index && !state.query ? "true" : "false";
    return `<button type="button" class="emoji-group" data-emoji-group="${index}"` +
      ` aria-pressed="${active}">${shortGroupName(group.name)}</button>`;
  }).join("");
}

function searchEmojiData(data, query) {
  const needle = query.toLowerCase();
  const found = [];

  for (const entry of data.all) {
    if (!entry.words.includes(needle)) continue;
    found.push(entry);
    if (found.length >= EMOJI_MAX_CELLS) break;
  }

  return found;
}

function renderEmojiPicker(root) {
  const state = emojiPickerState(root);
  const grid = root.querySelector("[data-emoji-grid]");
  const chips = root.querySelector("[data-emoji-groups]");
  const note = root.querySelector("[data-emoji-note]");
  const selected = root.querySelector("[data-emoji-input]")?.value || "";
  const recent = (root.dataset.emojiRecent || "").split(/\s+/).filter(Boolean);

  if (!grid) return;

  let list;
  let message;

  if (state.query) {
    list = state.data ? searchEmojiData(state.data, state.query) : [];
    message = state.data
      ? `${list.length}${list.length >= EMOJI_MAX_CELLS ? "+" : ""} hasil untuk “${state.query}”`
      : "Mencari seluruh emoji…";
  } else if (state.group !== null && state.data) {
    const group = state.data.groups[state.group];
    list = group ? group.entries : [];
    message = group ? group.name : "";
  } else {
    list = recent.map((char) => (state.data ? state.data.byChar.get(char) : null) || { char, words: "" });
    message = state.failed
      ? "Daftar lengkap gagal dimuat — pakai kolom emoji lain."
      : "Sering dipakai. Ketik untuk mencari di seluruh emoji.";
  }

  grid.innerHTML = emojiCells(list, selected);
  if (chips) chips.innerHTML = emojiChips(state);
  if (note) note.textContent = message;
}

function openEmojiPicker(root, open) {
  const panel = root.querySelector("[data-emoji-panel]");
  const toggle = root.querySelector("[data-emoji-toggle]");
  if (!panel) return;

  panel.hidden = !open;
  if (toggle) toggle.setAttribute("aria-expanded", open ? "true" : "false");
  if (!open) return;

  const state = emojiPickerState(root);
  renderEmojiPicker(root);
  if (state.data || state.loading) return;

  state.loading = true;
  reloadEmojiPicker(root);
}

// Only the picker that asked is redrawn: a second panel may already have been
// swapped in behind this one, and its own load settles it.
function reloadEmojiPicker(root) {
  const state = emojiPickerState(root);

  loadEmojiData().then((raw) => {
    state.data = parseEmojiData(raw);
    state.loading = false;
    renderEmojiPicker(root);
  }).catch(() => {
    state.loading = false;
    state.failed = true;
    renderEmojiPicker(root);
  });
}

function chooseEmoji(root, face) {
  const field = root.querySelector("[data-emoji-input]");
  const faceButton = root.querySelector("[data-emoji-toggle]");
  const custom = root.querySelector("[name=emoji_custom]");

  if (field) field.value = face;
  if (faceButton) faceButton.textContent = face;
  // A click outranks the echo of an off-roster face: leaving it there would let
  // the field read as edited when the cell is what was chosen.
  if (custom) custom.value = "";

  root.querySelectorAll("[data-emoji-cell]").forEach((cell) => {
    cell.setAttribute("aria-selected", cell.dataset.emojiCell === face ? "true" : "false");
  });

  openEmojiPicker(root, false);
}

function closeOtherEmojiPickers(except) {
  document.querySelectorAll("[data-emoji-picker]").forEach((root) => {
    if (root === except) return;
    const panel = root.querySelector("[data-emoji-panel]");
    if (panel && !panel.hidden) openEmojiPicker(root, false);
  });
}

document.addEventListener("click", (event) => {
  const root = event.target.closest("[data-emoji-picker]");
  closeOtherEmojiPickers(root);
  if (!root) return;

  if (event.target.closest("[data-emoji-toggle]")) {
    const panel = root.querySelector("[data-emoji-panel]");
    openEmojiPicker(root, !panel || panel.hidden);
    return;
  }

  const cell = event.target.closest("[data-emoji-cell]");
  if (cell) {
    chooseEmoji(root, cell.dataset.emojiCell);
    return;
  }

  const chip = event.target.closest("[data-emoji-group]");
  if (chip) {
    const state = emojiPickerState(root);
    const index = Number(chip.dataset.emojiGroup);
    const search = root.querySelector("[data-emoji-search]");

    state.group = index < 0 ? null : index;
    state.query = "";
    if (search) search.value = "";
    renderEmojiPicker(root);
  }
});

document.addEventListener("input", (event) => {
  const search = event.target.closest?.("[data-emoji-search]");
  if (!search) return;

  const root = search.closest("[data-emoji-picker]");
  const state = emojiPickerState(root);

  state.query = search.value.trim();
  state.group = null;
  // Typing into the field opens the roster: the search is what asks for it.
  openEmojiPicker(root, true);
});

document.addEventListener("keydown", (event) => {
  const search = event.target.closest?.("[data-emoji-search]");
  if (!search) return;

  const root = search.closest("[data-emoji-picker]");

  if (event.key === "Escape") {
    // Escape belongs to the picker here, not to the persona panel behind it.
    event.stopPropagation();
    openEmojiPicker(root, false);
    return;
  }

  // The field sits in the persona form, so Enter would submit it. The first
  // cell is what was being looked for, so Enter takes it instead.
  if (event.key === "Enter") {
    event.preventDefault();
    const first = root.querySelector("[data-emoji-cell]");
    if (first) chooseEmoji(root, first.dataset.emojiCell);
  }
});

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
// The badge on the app icon
// ---------------------------------------------------------------------------
//
// The same number the drawer's handle wears, on the icon a home screen shows:
// an installed app can say "something came in" without being opened. It is read
// from the page rather than kept anywhere else, and re-read after every swap —
// so a mark written by a turn that finished in another persona is on the icon
// in the same moment it is on the handle.
//
// A browser without the API simply has no icon to badge, and an install with
// nothing waiting clears it instead.

function syncAppIconBadge() {
  if (!navigator.setAppBadge && !navigator.clearAppBadge) return;

  const badge = document.getElementById("nav-badge");
  // A page without the mark has nothing to say about the count, and it must not
  // say "zero": the drawer's handle carries it, so the settings page (which
  // loads this file for its own controls) would otherwise clear an icon a turn
  // in another persona had just marked.
  if (!badge) return;

  const total = Number(badge.dataset.total || 0);
  const answer = total > 0 && navigator.setAppBadge
    ? navigator.setAppBadge(total)
    : (navigator.clearAppBadge ? navigator.clearAppBadge() : null);

  if (answer && typeof answer.catch === "function") answer.catch(() => {});
}

document.addEventListener("htmx:afterSwap", syncAppIconBadge);
// The header that carries the count arrives out of band, and htmx announces an
// out-of-band replacement under its own name, on the element it replaced.
document.addEventListener("htmx:oobAfterSwap", syncAppIconBadge);
window.addEventListener("pageshow", syncAppIconBadge);
// This file is read in the head, before there is a page to read the count off,
// so the first reading waits for the markup to exist.
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", syncAppIconBadge);
} else {
  syncAppIconBadge();
}

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------
//
// The button in the settings page asks this device to be woken when something
// happens
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

function pushRegistration() {
  // The toggle lives in the settings page, and a device may reach it before it
  // has ever opened a conversation — so there may be no worker registered yet.
  // Registering is idempotent (the worker's own script is the same file), and
  // `ready` below only resolves once one is active.
  navigator.serviceWorker.register("/sw.js").catch(() => {});

  // `ready` waits for an active worker; if the worker failed to install it
  // waits forever, which would look like a button stuck on "memuat". A
  // timeout turns that into an honest "tidak didukung".
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
// is still being parsed: the control does not exist yet, and a lookup here would
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
