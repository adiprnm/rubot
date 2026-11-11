# Rencana Optimasi Prompt Caching — rubot

Sumber:

- OpenAI API guide — Prompt caching (`developers.openai.com/api/docs/guides/prompt-caching`)
- OpenAI Cookbook — Prompt Caching 201 (`.../cookbook/examples/prompt_caching_201`)
- Claude Platform — Prompt caching (`platform.claude.com/docs/en/build-with-claude/prompt-caching`)

Status: rencana, belum dikerjakan.

---

## 0. Ringkasan

rubot sudah jauh di depan soal cache: system prompt di-*pin* per epoch, memory dan bagian volatil ditaruh di ujung prompt, trim history di-*block-aligned*, tool result lama dipotong per blok, dan hit rate sudah dilaporkan. Yang tersisa hampir semuanya soal **menutup kebocoran** dan **mengukur penyebabnya**, bukan membangun ulang fondasi.

Lima aksi dengan dampak terbesar:

| # | Aksi | Dampak |
|---|------|--------|
| 1 | **Instrumentasi sebab-miss** (divergence probe + label penyebab) — **sudah dikerjakan (item 1–3)** | Tanpa ini, optimasi berikutnya cuma tebak-tebakan |
| 2 | **Hilangkan dua mutator tengah-transcript** (`reasoning_tail` per turn, epoch churn) | Mengembalikan hit untuk 1–2 turn terakhir di setiap request |
| 3 | **Perbaiki akuntansi biaya** (`cached_input` kosong di 2.568/8.832 entri pricing, premium cache-write belum dihitung) | Hit rate bisa benar tapi angka $ bohong → keputusan salah |
| 4 | **Kirim `cache_control` di provider Anthropic** (sekarang tidak ada sama sekali → caching nol di Claude) | Besar untuk persona yang diarahkan ke Claude — **tapi lihat catatan baseline di bawah: akun ini belum punya trafik Anthropic sama sekali** |
| 5 | **Ganti `/repin` dengan append** (mid-conversation `role: "system"` di model yang mendukung) | Memory/skill baru masuk tanpa membatalkan prefix |

**Catatan dari baseline (2026-11-11, lihat `PROMPT_CACHING_BASELINE.md`):** seluruh
9.174 request di arsip berjalan ke gateway OpenAI-compatible
(`deepseek-v4.1-flash`, `glm-5.3-flash`, `mimo-v2.6-flash`) — tidak ada satu pun
request Anthropic. Jadi aksi `cache_control` tetap benar untuk dikerjakan, tapi
ia bukan lagi item berdampak terbesar untuk akun ini: ia perbaikan kebenaran
yang tidak bisa diukur sampai ada persona yang memakai model Claude. Yang bisa
diukur sekarang adalah distribusi miss di trafik deepseek (median 99,2%, tapi
22 dari 371 request sampel membaca 0 token dari cache).

Prinsip kerja: **ukur dulu, satu perubahan per commit, dan setiap perubahan harus punya angka sebelum/sesudah** (sesuai preferensi benchmarking).

---

## 1. Aturan dari dokumentasi (yang mengikat desain)

### OpenAI

- Prefix harus **identik persis**, minimal **1.024 token**, hit terjadi dalam kelipatan **128 token**. Berlaku otomatis, tanpa biaya tambahan.
- Seluruh prefix bisa di-cache: messages, images, **tool definitions**, schema structured output.
- Yang **mengubah prefix** (tabel "Which settings affect the cached prefix"): `model`, `tools` (nama/deskripsi/schema/**urutan**/instruksi tool), `parallel_tool_calls`, `text.format`, `reasoning.effort`, `text.verbosity`, `context_management`.
- Model pra-5.6: pakai `prompt_cache_key` **stabil** supaya request berbagi prefix mendarat di mesin yang sama; target ~**15 req/menit per key**, key memengaruhi routing, **bukan jaminan hit**.
- GPT-5.6+: routing otomatis; kontrol lewat `prompt_cache_options.mode` (`implicit`/`explicit`), `prompt_cache_breakpoint` per blok, `prewarm: true`, retensi sampai 24 jam.
- Resep: instruksi stabil di depan, konten dinamis (timestamp, data user) di **belakang**; **append**, jangan rewrite; compaction/truncation memotong reuse.
- Gotcha: *shared prefix ≠ cached prefix* (tanpa breakpoint setelah konten statis, write menulis-melewati konten dinamis sehingga prefix pendek tak pernah bisa dipakai ulang); *extending a message can prevent reuse*; *compaction can reduce cache reuse*; minimum length berbeda per model.

### Anthropic

- **Opt-in.** Tanpa `cache_control` → tidak ada cache sama sekali. Dua cara: top-level `cache_control` (otomatis, breakpoint di blok cacheable terakhir) atau `cache_control` per blok (eksplisit).
- Hierarki invalidasi: **`tools` → `system` → `messages`**. Ubah tool = seluruh cache mati; ubah system = system + messages mati.
- Cache **hanya ditulis di breakpoint**; pembacaan menengok ke belakang maksimal **20 blok**; maksimal **4 breakpoint**; breakpoint sendiri gratis.
- Minimum cacheable: **512** token (Opus 5.5/5, Sonnet 5.5, Haiku 5.5, Fable/Mythos 5.x), **1.024** (Opus 4.8, Sonnet 5/4.6/4.5), **2.048** (Opus 4.7), **4.096** (Opus 4.6/4.5, Haiku 4.5). Di bawah minimum: tidak ada cache, **tidak ada error** (hanya `cache_*_input_tokens` = 0).
- TTL 5 menit, **diperpanjang gratis tiap kali dibaca**. 1 jam = write 2× harga base (5 menit = 1,25×), read 0,1×. Kalau TTL dicampur, entri 1 jam harus **di depan** entri 5 menit.
- Invalidasi lain: `tool_choice` (messages), gambar, **thinking config & `output_config.effort`** (message cache selalu, tool/system tergantung model), thinking block yang di-drop, urutan key di `tool_use` yang tidak stabil.
- Fitur yang relevan untuk rubot: **mid-conversation `role: "system"` message** (Opus 5.5/4.8/5, Sonnet 5.5, Haiku 5.5, Fable/Mythos — **tidak** di Sonnet 5) → instruksi baru tanpa membatalkan cache; pre-warm via **`max_tokens: 0`**; `cache diagnostics` untuk menunjukkan titik divergensi; untuk request paralel, entri cache baru ada **setelah response pertama mulai**.
- Kolom usage: `cache_read_input_tokens`, `cache_creation_input_tokens`, `input_tokens` (hanya yang **setelah breakpoint terakhir**) → total input = jumlah ketiganya.

**Konsekuensi angka:** potensi penghematan 90% biaya input dan 80% time-to-first-token hanya berlaku kalau prefix-nya benar-benar dipakai ulang. Cache-write adalah biaya (1,25×), jadi menulis prefix yang tidak akan dipakai lagi lebih mahal daripada tidak caching.

---

## 2. Audit kondisi sekarang

| Area | Kondisi di kode | Nilai | Catatan |
|------|-----------------|-------|---------|
| System prompt pinning | `agent.rb#build_system_prompt` + `system_prompt_epoch` (model, rules, persona, summary, forced skill, task) | Kuat | Sudah setara best practice "preserve the prefix" |
| Urutan prompt | `compose_system_prompt`: aturan → soul → persona → skills → model → workspace → memory (volatil di ujung) | Kuat | Sesuai "dynamic content at the end" |
| Trim history | `session.rb#safe_history`, `TOKEN_TRIM_TARGET_FRACTION = 0.8`, batas bergerak per blok | Kuat | Lebih baik dari default de facto |
| Trim tool result | `agent.rb#trim_old_tool_results!` (keep N terbaru, sisanya dipotong, argumen diredaksi, per blok) | Kuat | Mutasi tengah transcript, tapi bergerak jarang |
| Provider Anthropic | `providers/anthropic.rb#build_payload` — **tidak ada `cache_control`**, `system` dikirim sebagai string polos | **Rusak** | Caching = 0 di semua model Claude |
| Provider OpenAI | `build_payload` chat completions — **tidak ada `prompt_cache_key`** | Lemah | Routing tanpa afinitas; hit bergantung keberuntungan |
| `reasoning_tail` | `build_messages` mengirim `reasoning_content` hanya untuk turn berjalan | **Bocor** | Setiap turn mengubah blok di ujung transcript yang baru saja ditulis → ~1 turn terakhir selalu harus dibaca ulang |
| Epoch churn | Memory/skill/AGENTS.md baru hanya masuk lewat `/repin` (1 request uncached penuh) | Sedang | Bisa diganti append di model yang mendukung |
| Akuntansi biaya | `usage.rb` sudah membaca `cache_read`/`cache_creation`; `model_pricing.json` punya **2.568 entri `cached_input: null`** dari 8.832; premium write (1,25×/2×) tidak dihitung | **Menyesatkan** | Cache bisa tampak "gratis" atau hit rate benar tapi $ salah |
| Metrik | `agent.rb#usage_report` (`cache_hit_rate`), `session.rb#cache_history` (12 request terakhir) | Cukup untuk tren | Belum ada diagnosis *penyebab* miss |
| Tool set | `Tools::Registry#register_defaults` — 8 tool tetap + memory tool, urutan `Hash` stabil | Kuat | Jaga jangan sampai berubah mid-session |

---

## 3. Rencana

### Fase 0 — Baseline & instrumentasi (prasyarat, jangan dilewati)

**Tujuan:** setiap miss punya label penyebab, dan ada angka baseline yang bisa dibandingkan.

1. **Per-request cache record** yang disimpan ke SQLite (bukan hanya 12 angka terakhir):
   `ts, provider, model, prompt_tokens, cached_tokens, cache_creation_tokens, input_after_breakpoint, epoch_digest, tools_digest, turns, block_count`.
2. **Divergence probe (murah, versi lokal dari cache diagnostics):** simpan `sha256` per blok (system, tiap tool, tiap pesan) untuk request terakhir. Saat `cached_tokens == 0` dan sebelumnya ada request, cari indeks blok pertama yang berbeda → label `first_divergence: system | tool:<nama> | message:<idx>`.
3. **Label penyebab** yang dipetakan dari probe + state:
   `cold`, `model_switch`, `prompt_epoch` (rules/persona/summary/skill/task), `tools_change`, `trim_boundary`, `tool_result_shrink`, `reasoning_tail`, `ttl_expiry`, `below_min_length`, `compaction`, `effort_change`.
4. **Baseline** yang dicatat sebelum menyentuh apa pun, per provider:
   hit rate median, distribusi hit rate per kategori sesi (interaktif vs cron), token re-read per miss, jumlah miss per sesi, $/turn.
   **Sudah diambil:** `PROMPT_CACHING_BASELINE.md` (2026-11-11), direproduksi dengan `bin/cache_baseline.rb`.

**Kriteria terima:** `rubot /context` (atau header web) bisa menjelaskan satu miss dengan label, dan baseline tersimpan di file/dokumen sebagai angka awal.
**Risiko:** rendah — read-only, satu kolom/probing per request.

---

### Fase 1 — Provider Anthropic: aktifkan caching (perbaikan kebenaran, belum terukur di akun ini)

**Tujuan:** Claude berhenti membayar penuh untuk prefix yang identik.
**Status dampak:** nol trafik Anthropic di arsip (lihat baseline) — kerjakan sebagai
perbaikan kebenaran, dan ukur dengan satu sesi uji Claude sebelum mengklaim
perbaikan biaya.

1. `build_payload`: `system` jadi array blok dengan breakpoint di blok terakhir:
   ```ruby
   "system" => [{ "type" => "text", "text" => system_prompt,
                  "cache_control" => { "type" => "ephemeral" } }]
   ```
2. Tool: taruh `cache_control` di **tool definition terakhir** (tool cache adalah level tertinggi → perubahan tool memang membatalkan semua, jadi taruh di sini supaya tetap ada write meski system berubah).
3. Messages: **rolling breakpoint** di blok terakhir request (`anthropic_message` perlu mengembalikan `content` berbentuk array kalau mau ditandai).
4. Layout 4 breakpoint yang direkomendasikan: `tools[-1]` → `system[-1]` → **anchor** (pesan terakhir turn sebelumnya, blok stabil) → `messages[-1]`. Anchor inilah yang menyelamatkan turn tool-heavy yang panjang (>20 blok) dari jendela lookback.
5. **Guard minimum length:** hitung estimasi token `tools + system + prefix`; kalau di bawah minimum per model (512 / 1.024 / 2.048 / 4.096 — tabel di atas), jangan pasang breakpoint dan catat `below_min_length`. Kalau sering kejadian di persona kecil, opsi berikutnya adalah menambah blok referensi stabil (bukan padding) supaya melewati ambang.
6. **TTL config** `cache_ttl: 5m | 1h` (default 5m). Aturan: 1 jam hanya untuk sesi dengan jeda antar-turn > 5 menit (turn agentic panjang, cron); kalau dicampur, entri 1 jam wajib di depan.

**Kriteria terima:** pada sesi Claude interaktif ≥5 turn, `cache_read_input_tokens` > 0 dari turn kedua, hit rate ≥ 60% median, dan `cache_creation` hanya muncul di turn pertama / setelah perubahan prefix yang sah. Unit test: bentuk payload (posisi breakpoint, jumlah ≤ 4) dan tidak ada breakpoint saat di bawah minimum.

**Risiko:** sedang — cache-write 1,25× kalau breakpoint dipasang di blok yang berubah tiap request. Mitigasi: breakpoint hanya di blok stabil + rolling di ujung; ukur via Fase 0.

---

### Fase 2 — Akuntansi biaya & tampilan (supaya keputusan tidak salah)

1. `model_pricing.json`: entri dengan `cached_input: null` → fallback per famili (0,1× input untuk Claude/OpenAI, 0,3× untuk deepseek-style) atau tandai `cached_unknown: true` dan sembunyikan angka $ (jangan tampilkan $0).
2. `usage.rb#build_cost`: tambahkan `cache_creation` dengan rate premium (1,25× untuk 5m, 2× untuk 1h) — sekarang write tidak terlihat sebagai biaya.
3. Tampilkan di `/context` + header web: hit rate, token re-read turn ini, **label penyebab** (dari Fase 0), dan estimasi $ yang dihemat.

**Kriteria terima:** biaya hasil `usage_report` cocok dengan invoice untuk satu sesi yang punya campuran read/write/miss (selisih < 5%).

---

### Fase 3 — Tutup dua mutator tengah-transcript

1. **`reasoning_tail`**: sekarang isi `reasoning_content` bergantung pada turn berjalan, jadi blok di ujung transcript berubah setiap turn. Pilihan, per provider:
   - OpenAI-compatible / DeepSeek: **jangan pernah** menulis `reasoning_content` ke transcript yang dikirim (`reasoning_in_history: false`) → transcript stabil.
   - Anthropic dengan thinking: biarkan thinking block apa adanya (dokumen: block yang dikembalikan apa adanya menjaga cache; block yang di-drop membatalkan dari posisi itu).
   Tambahkan test yang memastikan payload turn N+1 identik dengan turn N untuk semua blok sebelum pesan user baru.

   **Terverifikasi bukan sumber miss (2026-11-11) — jangan diubah tanpa data baru.**
   Dua alasan, keduanya dari pengukuran:
   - Pada 72 record `request_cache` dari sesi web live, tidak ada satu pun yang divergen
     di ekor transcript. Divergensi yang tercatat semuanya di tengah (`diverged_at` 10–339),
     artinya blok yang berubah adalah blok yang dipotong/ditulis ulang, bukan reasoning.
   - Reasoning hanya dibuang **sekali** per batas turn, bukan tiap request: `reasoning_tail`
     membuang reasoning milik jawaban yang sudah selesai, dan sejak request berikutnya
     blok itu tidak berubah lagi. Harness simulasi (`/tmp/reasoning_sim.rb`, 200 turn)
     menghasilkan **0** penulisan ulang berulang — biayanya satu blok per turn, bukan
     satu blok per request.

   Jadi yang tersisa dari item ini bukan kode, melainkan catatan: kebijakan sekarang
   sudah memberi hasil yang diinginkan (transcript stabil setelah satu request), dan
   `reasoning_in_history: false` akan menghapus konteks yang masih dipakai model
   OpenAI-compatible tanpa menghemat satu token pun. **Ditutup sebagai terverifikasi.**
2. **Epoch churn → append, bukan rebuild.** Untuk model yang mendukung mid-conversation `role: "system"` (Opus 5.5/4.8/5, Sonnet 5.5, Haiku 5.5, Fable/Mythos), memory/skill/AGENTS.md baru dikirim sebagai pesan system tambahan di `messages` → prefix tetap valid, hanya blok baru yang diproses. `/repin` tetap ada untuk rebuild penuh. Model yang tidak mendukung (Sonnet 5) jatuh ke perilaku sekarang.
3. **Kebijakan model/effort:** ganti model di tengah sesi = miss penuh (sudah ditangani lewat epoch), tapi ganti `thinking level` juga mengubah `reasoning_effort` → menurut tabel OpenAI & Claude itu memotong cache. UI picker di bawah composer sebaiknya menandai ini (ikon/warning kecil) dan mencatat `effort_change` di metrik, bukan memperlakukannya sebagai regresi.
4. **Pertahankan** block-alignment di `safe_history` dan `trim_old_tool_results!`; tambahkan penghitung "pergerakan batas per sesi" supaya bisa dibedakan dari penyebab lain.

**Kriteria terima:** pada sesi 10 turn tanpa epoch/trim/effort change, miss per turn = 0 kecuali turn pertama; hit rate ≥ 85% median.

---

### Fase 4 — Cadence: prewarm, TTL, dan paralelisme

1. **Prewarm saat channel mulai** (web/telegram) dan **sebelum cron job**: Anthropic `max_tokens: 0` dengan breakpoint yang sama; OpenAI (5.6+) `prompt_cache_options.prewarm: true`. Biaya write tetap ada, jadi prewarm hanya untuk prefix yang pasti dipakai (persona default, bukan semua persona).
2. **Distribusi jeda antar-turn** diukur dari record Fase 0 → keputusan 5m vs 1h diambil dari data, bukan asumsi.
3. **Request paralel**: di Anthropic, entri cache baru tersedia setelah response pertama mulai. `execute_tool_calls` menjalankan beberapa call bersamaan — untuk sub-agent yang berbagi prefix, jalankan **satu lebih dulu**, baru fan-out; atau terima miss untuk fan-out dan catat sebagai `cold_parallel`.
4. **Compaction**: beri anotasi di metrik supaya miss setelah compaction terbaca sebagai `compaction`, bukan regresi; opsi lanjutan: prewarm prefix hasil compaction.

---

### Fase 5 — OpenAI: routing & mode eksplisit

1. **`prompt_cache_key` stabil**: digest dari `persona + workspace + model + tools_digest`. **Jangan** pakai session id sebagai key utama (routing afinitas justru ingin request berbagi prefix di key yang sama). Kalau volume satu key melampaui ~15 req/menit, partisi deterministik: `key + ":" + (session_id_hash % N)`.
2. **Reasoning effort** sudah dikirim per request (`reasoning_effort` di `openai.rb`); pastikan ia tidak berubah diam-diam per turn (mis. dari preset) — kalau berubah, catat `effort_change`.
3. Kalau nanti migrasi ke **Responses API / GPT-5.6+**: pakai `mode: "explicit"` dengan `prompt_cache_breakpoint` setelah blok statis (tools + system) dan **jangan** menulis suffix dinamis (pelajaran dari gotcha "shared prefix is not a cached prefix"); pertimbangkan retensi diperpanjang untuk sesi panjang.
4. Selama masih chat completions di model pra-5.6: pastikan `system + tools` ≥ 1.024 token untuk persona yang dipakai sering — kalau di bawah, caching tidak pernah aktif (silent).

---

### Fase 6 — Guardrail & alert

1. Alert: **3 request berurutan dengan hit rate 0** pada prefix yang sama → log warning berisi `first_divergence`.
   - *Dikerjakan (commit `2ec184e`):* `CacheDiagnosis.miss_streak` menghitung read 0 berurutan pada prefix yang **tidak bergerak** (model, epoch, katalog tool sama, `diverged_at` negatif). Miss yang sudah dijelaskan — trim, tulisan ulang — memutus rentetan, karena prefix yang berubah memang tidak punya apa pun untuk dipakai ulang. `Session#record_cache_record` memperingatkan di hitungan ke-3 lalu tiap 10 setelahnya.
2. Laporan mingguan: hit rate + token re-read per provider/model; bandingkan dengan baseline Fase 0.
   - *Dikerjakan:* `bin/cache_weekly.rb [db] [--days 7]` membaca `request_cache` satu jendela, menampilkan hit weighted/median, request 0%, token re-read, tabel per model, daftar prefix yang bergeser beserta ukuran re-read-nya, dan rentetan 0% pada prefix utuh — semuanya di sebelah angka baseline.
3. Test regresi payload (lihat checklist di bawah) dijalankan di CI supaya perubahan prompt tidak diam-diam mematikan cache.

---

## 4. Definisi metrik

| Metrik | Rumus | Dipakai untuk |
|--------|-------|---------------|
| `hit_rate` | `cached / (input + cached + creation)` | Kesehatan umum, per turn |
| `re_read_tokens` | total input yang dibayar rate penuh saat miss | Biaya churn prefix |
| `mislabel` | label penyebab per miss (Fase 0) | Prioritas perbaikan |
| `$ per turn` | dari `usage.rb` (setelah Fase 2) | Angka bisnis |
| `first_divergence` | indeks blok pertama yang berbeda | Diagnosis akar masalah |

Target setelah semua fase: hit rate median **≥ 85%** untuk sesi interaktif multi-turn, `cold`/`epoch`/`compaction` sebagai satu-satunya penyebab miss yang sah, dan biaya input per turn turun **≥ 60%** dibanding baseline.

---

## 5. Yang jangan dilakukan

- **Jangan** memasang breakpoint di blok yang berubah tiap request (pesan user terakhir saja pada Anthropic itu justru write sia-sia kalau dipakai sebagai satu-satunya titik; rolling + anchor yang benar).
- **Jangan** menaruh timestamp, tanggal hari ini, isi todo, atau inventaris file di bagian stabil prompt — bagian volatil tetap di ujung.
- **Jangan** rewrite turn lama untuk summarization di tengah percakapan; gunakan compaction di batas, dan terima/di-annotate miss-nya.
- **Jangan** mengubah tool set (nama, deskripsi, schema, **urutan**) mid-session; kalau perlu, lakukan di batas epoch atau lewat `tool_addition` beta di Anthropic.
- **Jangan** lebih dari 4 breakpoint; kalau butuh lebih, itu tanda blok statisnya terlalu terpecah.
- **Jangan** mematikan pin system prompt demi "selalu up to date" — biayanya satu re-read penuh seluruh transcript, bukan satu baris.

---

## 6. Checklist verifikasi (test yang harus ada)

| Aturan dokumen | Test |
|----------------|------|
| System prompt identik antar request selama epoch sama | payload turn 2..N: `system` byte-identik |
| Append, bukan rewrite | payload turn N+1 memuat prefix pesan turn N tanpa perubahan |
| `reasoning_tail` tidak mengubah blok lama | membandingkan blok ke-i untuk i < batas (Fase 3) |
| Urutan key `tool_use` stabil | serialize dua kali → JSON identik |
| Breakpoint Anthropic ≤ 4 & di blok stabil | assert posisi + jumlah; assert tidak ada saat < minimum model |
| Hierarki invalidasi Claude | ubah tool → assert write penuh berikutnya; ubah messages → assert read tetap |
| `cache_read` hanya dipakai kalau TTL belum lewat | fake clock + assert `cache_ttl` memilih 1h hanya sesuai kebijakan |
| `prompt_cache_key` stabil lintas restart | restart proses → key sama untuk persona+model yang sama |
| Trim bergerak per blok | 200 append → jumlah pergerakan batas ≤ N/blok |
| Cost memasukkan write premium | kasus campuran read+write → total cocok dengan hitungan manual |

---

## 7. Urutan kerja & estimasi

| Fase | Isi | Ukuran | Alasan urutan |
|------|-----|--------|---------------|
| 0 | Baseline + probe + label penyebab | M | Semua angka sesudahnya bergantung di sini |
| 1 | Anthropic `cache_control` | M | Dampak terbesar, risiko terisolasi di satu file |
| 2 | Akuntansi biaya | S | Supaya Fase 1 bisa dinilai dalam $ |
| 3 | `reasoning_tail` + epoch→append | M | Mengembalikan hit yang paling sering hilang |
| 4 | Prewarm/TTL/paralel | M | Baru berguna setelah Fase 1–3 stabil |
| 5 | OpenAI `prompt_cache_key` (+ Responses 5.6+ nanti) | S–M | Menutup celah routing |
| 6 | Guardrail, alert, CI | S | Menjaga hasil tidak mundur |

Satu fase = satu commit (atau beberapa commit kecil per langkah), masing-masing dengan angka sebelum/sesudah di pesan commit.

---

## 8. Temuan pengukuran, 2026-11-11 malam (item 22)

Diukur dengan `bin/cache_loss.rb`, bukan dengan perasaan: 245 request, 2 sesi web,
gateway OpenAI-compatible (`deepseek-v4.1-flash`), 23,3 juta prompt token.

| sebab | n | token dibaca ulang | share |
|---|---|---|---|
| `window` — trim keras di depan transcript | 9 | 951.957 | 51,0% |
| `intact` — prefix utuh, provider tidak melaporkan cache | 3 | 350.952 | 18,8% |
| `boundary` — batas hasil-tool bergeser | 15 | 281.274 | 15,1% |
| `partial` — ekor turn berjalan (selalu ada) | 216 | 180.377 | 9,7% |
| `cold` — request pertama | 2 | 102.711 | 5,5% |

Total re-read 1,87 juta token = **8,0%** dari semua prompt token.

**Yang mengejutkan: bukan redaksi args tool yang mahal.** Item 22(b) menduga trim
dan redaksi jatuh berurutan sehingga ada dua re-read beruntun. Ternyata keduanya
memang berada di boundary yang sama (satu `older` block, satu request), dan biaya
gabungannya cuma 15% dengan rata-rata 18.751 token per event, jarak yang berubah
selalu 21–44 blok dari ujung — persis `tool_result_keep: 10`. **Tidak ada yang perlu
diubah di sana; usulan 22(b) ditutup.**

**Yang mahal adalah trim keras `max_messages`.** Setiap kali transcript menyentuh
cap (400 pesan di config ini), `Session#trim!` membuang satu blok pesan dari depan.
Itu menggeser blok pertama transcript → seluruh prefix setelah system+tools tidak
bisa dipakai lagi → satu re-read penuh ~110.000 token. Terukur 9 kali dalam 245
request, ~1.000.000 token (51% dari semua re-read), dan trim hanya membuang ~5–40
pesan tiap kali. Jadi biayanya tidak sebanding dengan yang dihemat.

Contoh dari data (2026-11-11 12:54–13:04):

```
12:54:31  turns=400  p=124.735  c=123.648   ← cap tersentuh, hit normal
12:54:42  turns=361  p=117.796  c=      0   ← trim: blok 10 berubah, re-read penuh
12:55:00  turns=363  p=119.221  c=      0   ← intact: provider belum punya prefix baru
12:55:07  turns=365  p=119.396  c=119.168   ← pulih
```

Baris `intact` mengikuti trim dengan pola yang sama tiga kali (12:54:10, 12:55:00,
12:58:57): request pertama setelah prefix berubah tidak mendapat cache read sama
sekali, request berikutnya pulih. Itu tanda entry baru belum terlihat (write lag)
atau mesin lain yang melayani, dan tidak ada yang bisa diperbaiki dari sisi prompt.
`prompt_cache_key` (item 18) hanya dikirim ke OpenAI, jadi gateway tidak tertolong
olehnya. Yang bisa dihindari adalah *penyebab* prefix berubah: trim-nya sendiri.

**Kesimpulan → item 23 (baru):** jangan biarkan trim keras terjadi. Transcript
sebaiknya di-*compaction* lebih dulu, karena compaction juga satu re-read penuh
tapi hasilnya lebih kecil (ringkasan + 10 pesan terakhir, bukan 360 pesan) dan
informasinya tidak hilang. Harness pengukur: `bin/cache_loss.rb`.

**Dikerjakan (item 23):** `Agent#run_auto_compaction` sekarang bertanya lebih dulu
`Session#near_trim_cap?` — satu blok sebelum `session_max_messages` — dan memanggil
compaction, bukan menunggu trim. Satu blok lebih awal karena trim mendarat satu blok
di bawah cap: bertanya tepat di cap akan terlambat satu append, saat trim sudah jalan.
Dua tes menjaga hubungan itu (`test_auto_compaction_fires_before_the_hard_message_trim`,
`test_near_trim_cap_reports_one_block_of_headroom`); predikatnya tinggal di `Session`
bersama trim yang dijaganya supaya keduanya tidak bisa melenceng.
