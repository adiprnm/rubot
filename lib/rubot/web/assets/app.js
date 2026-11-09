// Alpine glue for the chat shell. Everything that renders HTML lives on the
// Ruby side; this file only wires the composer and keeps the active-turn
// marker in sync with the SSE connection.
document.addEventListener("alpine:init", () => {
  Alpine.store("turn", { active: null });

  Alpine.data("composer", () => ({
    text: "",

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
      if (!text) return;

      const active = Alpine.store("turn").active;
      if (active) {
        // The turn already running owns the session; hand the text over
        // instead of queueing a second turn behind it.
        this.text = "";
        fetch(`/turns/${active}/steer`, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({ text }),
        });
        return;
      }

      this.$refs.form.requestSubmit();
    },

    // The one button beside the field. Sending goes through send() rather than
    // straight at the form, so an empty field is a no-op from the button just
    // as it is from Enter.
    sendOrStop() {
      if (Alpine.store("turn").active) this.stop();
      else this.send();
    },

    stop() {
      const active = Alpine.store("turn").active;
      if (!active) return;
      fetch(`/turns/${active}/stop`, { method: "POST" });
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

  const slot = document.getElementById("composer-notice");
  if (!slot) return;
  slot.innerHTML = "";
  slot.hidden = true;
});

// The SSE extension closes the stream when Ruby sends the `done` event; that
// is also the signal that the session is free again. Marking the turn done
// retires its blinking cursor.
for (const name of ["htmx:sseClose", "htmx:sseError"]) {
  document.addEventListener(name, () => {
    Alpine.store("turn").active = null;
    document
      .querySelectorAll(".turn:not(.is-done)")
      .forEach((turn) => turn.classList.add("is-done"));
  });
}

function scrollToBottom() {
  const thread = document.getElementById("thread");
  if (!thread) return;
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

document.addEventListener("htmx:sseMessage", scrollToBottom);
document.addEventListener("htmx:afterSwap", scrollToBottom);
document.addEventListener("htmx:afterSwap", syncDocumentTitle);

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
