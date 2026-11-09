# TODO — Per-topic persona (Telegram forum topics)

Status: **implemented** (2026-11-04)
Tanggal: 2026-02-11

## Tujuan

Setiap Telegram forum topic bisa punya persona sendiri: model LLM dan system
prompt berbeda per topic. Saat topic baru dibuat, bot menampilkan interface
setup (wizard) untuk memilih model dan mengisi system prompt.

## Kondisi saat ini (hasil investigasi)

Sudah per-topic:

- Session/riwayat: `session_id = "tg_#{chat_id}_#{thread_id}"` — `lib/rubot/channels/telegram.rb:605`
- Model override per session: `Session#model_override` → `Agent#use_model` — `lib/rubot/agent.rb:285-297`
- Delivery context cron & send_file per topic — `telegram.rb:613-619`

Masih global (satu untuk semua topic):

- `SOUL.md`, `AGENTS.md`, `MEMORY.md`, `skills/`, `sessions/` — semuanya dari
  satu `config.workspace` (`agent.rb:46-48`, `config.rb:117`)
- `SessionPool` mengambil snapshot config sekali di awal — `lib/rubot/actors/session_pool.rb:19`
- `CronActor` hanya satu, dibuat dari workspace global — `session_pool.rb:23`

Infrastruktur yang bisa dipakai ulang:

- Inline keyboard + callback query: `ask_confirmation` (`telegram.rb:835-892`),
  `handle_callback_query` (`telegram.rb:894`), `answer_callback_query` (`telegram.rb:919`)
- Ops Ractor per session: `SessionActor.handle_request` (`lib/rubot/actors/session_actor.rb:100-130`),
  contoh `:use_model` dan `:clear_session`
- Proxy ops di main Ractor: `SessionHandle#call` (`lib/rubot/session_handle.rb:24`)

## Keputusan default (bisa diubah)

1. MEMORY dan skills tetap dibagi semua topic (belum diisolasi per persona).
2. Wizard otomatis muncul saat topic baru dibuat, dan bisa dibuka ulang dengan `/persona`.
3. Semua user yang lolos `authorized?` boleh setup persona.
4. System prompt diketik lewat chat (bukan file), dengan opsi "pakai default"/"lewati".

## Rancangan

### 1. Penyimpanan persona

`workspace/personas.json`, key `"<chat_id>:<thread_id>"` (`thread_id` tidak unik
lintas chat, jadi wajib dipasangkan):

```json
{
  "-1001234567890:42": {
    "name": "trading",
    "model": "claude-sonnet",
    "system_prompt": "Kamu adalah asisten trading. Jawab singkat, fokus data.",
    "created_at": "2026-02-11T10:00:00Z"
  }
}
```

File-based supaya ikut volume Docker dan bisa diedit manual.

### 2. Wizard (3 langkah)

Trigger: update `message.forum_topic_created` — saat ini dibuang karena
`process_update` langsung `return unless text && !text.strip.empty?`
(`telegram.rb:596`). Perlu ditangani sebelum guard itu.

```
🧬 Setup persona untuk topic ini

Langkah 1/3 — Pilih model:
[ gpt-4o-mini ] [ claude-sonnet ] [ llama3 ]
[ Pakai default ]

Langkah 2/3 — Kirim system prompt (balas dengan teks):
[ Lewati / pakai default ]

Langkah 3/3 — Preview:
  Model : claude-sonnet
  Prompt: Kamu adalah asisten trading...
[ ✅ Simpan ] [ ✏️ Ulangi ] [ ❌ Batal ]
```

- Model list dari `config.models` (via `ra.config.models`).
- State wizard disimpan per topic di channel (bukan di session), dengan mutex
  dan TTL (mis. 15 menit) agar topic yang ditinggal tidak menggantung.
- Balasan teks saat langkah 2 di-intercept di `process_update` sebelum
  `before_process`, sehingga tidak dikirim ke agent.
- `/persona` → buka ulang wizard; `/persona show` → tampilkan persona aktif;
  `/persona reset` → hapus persona topic ini; `/cancel` → keluar wizard.
- `callback_data` dibatasi 64 byte, jadi pakai id pendek:
  `persona:<wizard_hex>:<action>:<index>`.
- Topic General (`thread_id == nil`) memakai persona default / config global.

### 3. Penerapan persona ke session

1. `SessionPool#for` (`session_pool.rb:39`) membaca persona dari store dan
   meneruskannya ke `SessionActor` → `Agent.new(..., persona:)`.
2. `Agent#system_prompt` (`agent.rb:342`) menyuntik blok `# Persona` setelah
   SOUL dan menggantikan `config.system_prompt` bila persona punya prompt.
3. Model persona diterapkan lewat `use_model` yang sudah ada.
4. Saat wizard disimpan untuk session yang actor-nya sudah hidup, kirim op baru
   `:set_persona` (pola sama seperti `:use_model`, `session_actor.rb:109`) agar
   tidak perlu restart actor dan riwayat percakapan tetap utuh.
5. Session baru mewarisi persona; `/new` hanya menghapus riwayat + model
   override, tidak menghapus persona.

## Rencana kerja

- [x] `lib/rubot/persona_store.rb` — load/save/lookup personas.json, validasi
      key & model, fallback ke default kalau model sudah tidak ada di config.
- [x] `lib/rubot/persona.rb` (opsional) — value object: name, model,
      system_prompt, created_at.
- [x] `agent.rb` — terima `persona:`, inject ke `system_prompt`, method
      `apply_persona(model:, prompt:)`.
- [x] `session_actor.rb` — op `:set_persona`, op `:persona` (baca), teruskan
      persona saat `Agent.new`.
- [x] `session_pool.rb` — lookup persona per session id saat spawn actor,
      plus helper invalidate/rebuild bila perlu.
- [x] `session_handle.rb` — proxy `persona`, `set_persona`.
- [x] `channels/telegram.rb`
  - [x] handle `forum_topic_created` → mulai wizard
  - [x] state machine wizard + mutex + TTL, intercept teks langkah 2
  - [x] handler callback `persona:` di `handle_callback_query`
  - [x] command `/persona`, `/persona show`, `/persona reset`, `/cancel`
  - [x] daftarkan `/persona` di `register_bot_commands` + teks `/help`
- [x] `config/rubot.example.yml` + `README.md` — dokumentasi fitur persona
      dan contoh `personas.json`.
- [x] Test: `test_persona_store.rb`, tambahan kasus di `test_agent.rb`
      (inject prompt), `test_actors.rb` (op `:set_persona`),
      `test_channels.rb` (wizard state).

## Catatan / risiko

- Bot harus admin di grup (atau privacy mode off) agar menerima
  `forum_topic_created`; kalau tidak, wizard baru muncul pada pesan pertama
  di topic tersebut (fallback: deteksi thread_id baru yang belum punya persona).
- Pesan service `forum_topic_created` juga muncul untuk topic yang dibuat bot;
  pastikan tidak memicu wizard berulang.
- Persona dengan model yang dihapus dari `config.yml` harus fallback ke model
  default + peringatan, bukan error.
- Isolasi MEMORY/skills per persona sengaja belum masuk scope; kalau nanti
  dibutuhkan, tambahkan `workspace/personas/<key>/` dengan `MEMORY.md` dan
  `skills/`, lalu perluas `Memory` dan `SkillRegistry` dengan `subdir:`.
- Jika nanti pindah ke workspace terpisah per persona, `CronActor` harus
  dipecah per workspace (saat ini satu actor per pool).

## Estimasi

~400 baris kode baru/ubahan + test.

## Update 2026-11-09 — memory per persona, shared skills, shared caches

Perubahan setelah fitur ini jalan:

1. **Memory per persona.** Sebuah persona kini punya `MEMORY.md` di direktorinya
   sendiri (`~/.rubot/personas/<slug>/MEMORY.md`), bukan `~/.rubot/memory/
   <path-slug>.md`. Config menandai ini lewat `memory_in_workspace`, jadi
   `workspace_memory_path` tidak perlu menebak dari bentuk path. Memory
   workspace non-persona (project TUI) tidak berubah.
2. **Label scope.** Untuk persona, lapisan lokalnya disebut `persona` (di tool
   `memory` maupun di preamble prompt), bukan `workspace`.
3. **Ekstraksi per item.** `SCOPE_BY_SECTION` dihapus. Tiap item yang diekstrak
   membawa `scope` sendiri; hanya `global` yang eksplisit yang keluar dari
   lapisan lokal. Ragu → lokal.
4. **Skills terpusat.** `SkillRegistry` membaca `Config#skills_workspace`
   (workspace utama), bukan direktori persona. Persona menyebut skill yang
   wajib dipakai lewat field `skills`, yang diinjeksi sebagai blok
   `# Required Skills` di system prompt.
5. **Topic menunjuk persona.** Key `"<chat_id>:<thread_id>"` boleh berisi
   `{"ref": "<slug>"}`. Topic memakai model, prompt, skills dan memory persona
   itu, tapi session-nya tetap sendiri (`tg_<chat>_<thread>`). Wizard `/persona`
   kini bertanya dulu: pakai persona yang ada, atau buat baru.
6. **Cache terpusat.** `model_pricing.json` dan `model_catalog.json` pindah ke
   samping `config.yml` (`Config#catalog_dir`), satu untuk semua persona.
   Salinan lama per persona/workspace dihapus lewat skrip one-off.
7. **Bug lama diperbaiki.** `topic_session_exists?` menunjuk
   `<workspace>/sessions`, padahal session sudah terpusat di
   `~/.rubot/sessions`; akibatnya setiap topic lama dianggap baru dan wizard
   muncul lagi.

Sisa catatan lama yang masih berlaku: `CronActor` tetap satu per pool (dibuat
dari workspace utama), jadi job cron tidak ikut workspace persona.
