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

    keydown(event) {
      if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
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
