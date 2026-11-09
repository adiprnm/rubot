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
      if (!text) return;

      const active = Alpine.store("turn").active;
      if (active) {
        // The turn already running owns the session; hand the text over
        // instead of queueing a second turn behind it.
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

    // The one button beside the field. Sending goes through send() rather than
    // straight at the form, so an empty field is a no-op from the button just
    // as it is from Enter.
    sendOrStop() {
      if (this.stopping) return;
      if (Alpine.store("turn").active) this.stop();
      else this.send();
    },

    // Stopping is a request, not a fact: the turn keeps running until the
    // server has acted on it. The button says so and stops accepting presses
    // for the round trip, then falls back to whatever the store says — the
    // stream closes on its own when the turn really ends, and that is what
    // puts the button back to "Kirim".
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

    // What the button reads, in one place: the template asks this rather than
    // nesting three ternaries in an attribute.
    get buttonLabel() {
      if (this.stopping) return "Membatalkan…";
      return Alpine.store("turn").active ? "Batal" : "Kirim";
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
  });
}

function scrollToBottom(event) {
  const el = event && event.detail && event.detail.elt;
  // An older page arrives *above* the reader. Jumping to the bottom would
  // throw them out of the place they were reading, so the prepend is left to
  // the handler below, which keeps them where they are.
  if (el instanceof Element && el.closest(".history-more")) return;

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

// A conversation is read from its end. The page only draws the tail of it, so
// the thread starts at the bottom — otherwise opening a session would put the
// reader in front of its oldest message.
document.addEventListener("DOMContentLoaded", scrollToBottom);

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

// The new-persona form is a dialog now: the page behind it is dimmed, and the
// dimmed part is a way out. `<details>` closes on its own summary, so only the
// two things it does not handle are wired here — a click on the backdrop and
// the Escape key. Without this the dialog could only be dismissed by the one
// button it was opened with, which the backdrop is covering.
document.addEventListener("click", (event) => {
  const open = document.querySelector("details.rail-new[open]");
  if (!open) return;

  if (open.querySelector("summary")?.contains(event.target)) return;
  if (open.querySelector(".rail-panel")?.contains(event.target)) return;

  open.open = false;
});

document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return;

  const open = document.querySelector("details.rail-new[open]");
  if (open) open.open = false;
});
