# frozen_string_literal: true

module Rubot
  # Every piece of text Rubot shows a person, in the languages it can be shown.
  #
  # One dictionary, two languages, one function. A channel never writes a
  # reader-facing sentence in place: it names a key here. That is what makes a
  # language switch a single assignment instead of a sweep through the TUI, the
  # web templates and the Telegram card, and what lets a test compare the two
  # dictionaries key by key (see test/test_i18n.rb).
  #
  # The key space is dotted and nested: `I18n.t("tool.shell.command")` reads
  # DICTIONARY["en"]["tool"]["shell"]["command"]. Values are frozen strings,
  # with `%{name}` for the parts a caller fills in; a value may not use Ruby's
  # `format` verbs, since `%` shows up in real labels ("100%").
  #
  # The locale is a process-wide setting, not an argument threaded through every
  # call: a channel sets it once from config (`Config#bahasa`), and a settings
  # change sets it again, so a new language is live on the next row drawn
  # instead of on the next launch. A Ractor that needs it passes the plain
  # string across its boundary like any other message.
  module I18n
    LOCALES = %w[en id].freeze
    DEFAULT_LOCALE = "en"
    # The config key this dictionary is chosen by: `bahasa: id` in config.yml.
    CONFIG_KEY = "bahasa"

    # A config or a caller named a language this build does not speak. Raised
    # instead of quietly falling back: a typo in `bahasa:` should be reported
    # where it is made, not discovered as a half-English interface.
    class UnknownLocale < ArgumentError; end

    # A key with no entry in any language. Raised in every environment: a
    # missing label is a blank row on someone's screen, and the parity test is
    # what keeps this from ever firing in production.
    class MissingTranslation < KeyError; end

    # `%{name}` and nothing else is a placeholder. Braces are literal.
    PLACEHOLDER = /%\{(\w+)\}/

    DICTIONARY = {
      "en" => {
        "thinking" => {
          "live" => "Thinking…",
          "done" => "Thought for %{duration}"
        },
        "compaction" => {
          "running" => "Summarizing the conversation…",
          "failed" => "Compaction failed",
          "done" => "Summarized %{count} messages · ~%{before} → ~%{after} tokens",
          "empty" => "Nothing to compact yet (the conversation is short or summarizing failed).",
          "note" => "Conversation summarized. Its seam is marked below, where the compaction happened.",
          "row_title" => "Automatic summary: older turns summarized to free up context",
          "row_done" => "Context summarized.",
          "row_detail" => "%{before} → %{after} tokens",
          "complete" => "Compaction complete.",
          "title" => "Compaction complete",
          "busy" => "A turn is still running. Summarize once it finishes: a conversation in flight must not be summarized.",
          "error" => "Summarizing failed. Try again in a moment.",
          "summarized" => "Summarized: %{count} messages",
          "kept" => "Kept: %{count} messages",
          "context" => "Context: ~%{before} → ~%{after} tokens (estimated)"
        },
        "footer" => {
          "turn" => "Turn took %{duration} (Total time %{total} · %{count} %{turns})",
          "turn_one" => "turn",
          "turn_other" => "turns"
        },
        "status" => {
          "working" => "working",
          "cancelling" => "cancelling",
          "cancels" => "esc cancels",
          "empty_message" => "Nothing to send.",
          "stop_requested" => "Stop requested."
        },
        "tool" => {
          "operation_unknown" => "%{prefix}: %{operation}",
          "name" => {
            "memory" => "Memory",
            "cron" => "Scheduled tasks",
            "loop" => "Loop",
            "instagram" => "Instagram"
          },
          "place" => {
            "here" => "this",
            "directory" => "this directory",
            "file" => "a file",
            "files" => "%{count} files",
            "in" => " in %{target}",
            "to" => " to %{target}",
            "on" => " on %{target}"
          },
          "wait" => {
            "seconds" => "%{count}s",
            "minutes" => "%{count}m",
            "minutes_seconds" => "%{minutes}m %{seconds}s",
            "hours" => "%{count}h",
            "hours_minutes" => "%{hours}h %{minutes}m",
            "days" => "%{count}d",
            "days_hours" => "%{days}d %{hours}h"
          },
          "shell" => {
            "command" => "Ran a command in the terminal",
            "directory" => "Showing what is inside %{target} directory",
            "read" => "Reading %{target}",
            "read_follow" => "Following the log live",
            "grep" => "Searching for %{pattern} in the files",
            "grep_bare" => "Searching for something in the files",
            "find" => "Looking for files%{where}",
            "mkdir" => "Creating a directory%{where}",
            "remove" => "Deleting %{target}",
            "move" => "Moving %{from}%{to}",
            "copy" => "Copying %{from}%{to}",
            "touch" => "Creating a file%{where}",
            "chmod" => "Changing the permissions%{where}",
            "count_lines" => "Counting the lines%{where}",
            "download" => "Fetching the page %{url}",
            "processes" => "Looking at the running processes",
            "kill" => "Stopping a process",
            "date" => "Showing the date and time",
            "sleep" => "Waiting %{duration}",
            "sleep_brief" => "Waiting a moment",
            "sleep_unbounded" => "Waiting without end",
            "locate" => "Finding where %{command} lives",
            "echo" => "Writing a short piece of text",
            "remote" => "Reaching another server",
            "database" => "Opening a database",
            "tests" => "Running the tests",
            "style" => "Checking the code style",
            "script" => "Running the %{language} script%{where}",
            "script_bare" => "Running %{language}",
            "rake" => "Running a rake task",
            "migrate" => "Running the database migrations",
            "go" => "Running a go command",
            "go_build" => "Building the program",
            "go_run" => "Running the program",
            "docker" => "Running docker %{command}",
            "archive" => "Packing or unpacking files",
            "service" => "Managing a system service"
          },
          "git" => {
            "status" => "Checking the git status",
            "diff" => "Reading the changes not saved yet",
            "log" => "Reading the commit history",
            "add" => "Marking the changes to commit",
            "commit" => "Saving the changes to git",
            "push" => "Sending the commits to the remote",
            "pull" => "Fetching the updates from the remote",
            "checkout" => "Switching branch%{where}",
            "branch" => "Reading the list of branches",
            "stash" => "Setting the changes aside",
            "show" => "Reading one commit in detail",
            "clone" => "Downloading a copy of the repository",
            "other" => "Looking after the git repository"
          },
          "package" => {
            "install" => "Installing the dependencies",
            "test" => "Running the tests",
            "run" => "Running a project script",
            "build" => "Building the project",
            "gem" => "Looking after the gems",
            "other" => "Looking after the dependencies"
          },
          "file" => {
            "read" => "Reading %{target}",
            "write" => "Writing %{target}",
            "edit" => "Editing %{target}",
            "append" => "Adding to %{target}",
            "delete" => "Deleting %{target}",
            "list" => "Showing what is in %{target}",
            "info" => "Looking at %{target}"
          },
          "memory" => {
            "read" => "Recalling what it wrote down",
            "append" => "Writing one thing down in memory",
            "update_section" => "Tidying one section of the notes"
          },
          "cron" => {
            "add" => "Scheduling a recurring task",
            "list" => "Reading the list of scheduled tasks",
            "detail" => "Reading one scheduled task",
            "remove" => "Cancelling a task",
            "enable" => "Turning a task on",
            "disable" => "Turning a task off"
          },
          "loop" => {
            "status" => "Reading where a loop stands",
            "list" => "Reading the list of loops",
            "pause" => "Pausing a loop",
            "resume" => "Resuming a stopped loop",
            "stop" => "Stopping a loop",
            "undo" => "Dropping the last iteration",
            "start" => "Starting a loop: %{goal}",
            "start_bare" => "Starting a new loop"
          },
          "instagram" => {
            "connect" => "Setting up the Instagram connection",
            "status" => "Checking the Instagram account",
            "schedule" => "Scheduling an Instagram post",
            "publish" => "Posting to Instagram",
            "posts" => "Reading the list of Instagram posts",
            "cancel" => "Cancelling an Instagram post",
            "link" => "Linking an Instagram account",
            "disconnect" => "Unlinking an Instagram account",
            "other" => "Looking after Instagram"
          },
          "subagent_results" => "Reading a sub agent's result",
          "notify" => "Getting ready to tell you when it is done",
          "send" => {
            "none" => "Sending files",
            "one" => "Sending a file",
            "many" => "Sending %{count} files"
          },
          "search" => {
            "files" => "Looking for files",
            "code" => "Searching the code",
            "files_named" => "Looking for files named \"%{pattern}\"",
            "code_for" => "Searching the code for \"%{pattern}\""
          },
          "fetch" => "Opening a page",
          "fetch_page" => "Opening %{url}",
          "delegate" => "Asking a sub agent for help",
          "delegate_named" => "Asking %{agent} for help"
        },
        # The settings page's own language field. It reads through the same
        # function as everything else, so the field that picks the language is
        # itself evidence of the language it picked.
        "settings" => {
          "language" => {
            "label" => "Language",
            "note" => "What Rubot writes in: the tool rows, the thinking block and the status line. Applies to every channel of this install.",
            "en" => "English",
            "id" => "Indonesian",
            "unknown" => "Language %{value} is not one this interface speaks: choose %{choices}."
          }
        },
        # The settings page: its own document, so its own namespace. These name
        # rows of a form, not rows of a conversation, and the page draws every
        # one of them through this dictionary rather than in place.
        "web" => {
          "settings" => {
            "title" => "rubot · settings",
            "back" => "back",
            "topbar" => "settings",
            "saved" => "Saved",
            "save" => "Save",
            "heading" => "Settings",
            "lead" => "Connection and models apply to every persona. Theme, font, and notifications apply to this device, and are saved the moment they are pressed.",
            "no_archive" => "The session archive is not open yet, so there is nowhere to save.",
            "tabs" => {
              "label" => "Settings sections",
              "connection" => "Connection",
              "appearance" => "Appearance",
              "presets" => "Model presets",
              "subagents" => "Subagents",
              "instagram" => "Instagram"
            },
            # One wording for both password fields: the key and the App Secret
            # are read the same way — a blank box means "leave it alone".
            "field" => {
              "key_stored" => "already stored, leave it empty to keep it",
              "key_missing" => "not set yet"
            },
            "connection" => {
              "provider" => "Provider",
              "api_key" => "API key",
              "key_from_archive" => "Stored in the install database. Tick to go back to config.yml.",
              "clear_key" => "Remove the key from the database",
              "no_key" => "Without a key, only a local provider such as ollama can answer.",
              "default_model" => "Default model",
              "auxiliary_model" => "Auxiliary model",
              "auxiliary_blank" => "Follow the default model",
              "auxiliary_note" => "For work behind the scenes: summarizing and naming sessions.",
              "subagent_model" => "Subagent model",
              "subagent_blank" => "Follow the subagent preset (flash)",
              "subagent_note" => "For every subagent. Leave it blank to use the built-in preset."
            },
            "appearance" => {
              "note" => "this device, saved the moment it is pressed",
              "theme" => "Theme",
              "font" => "Font",
              "font_note" => "Serif is the default. Georgia and Palatino use the device's own faces, so they can look a little different. The machine name stays monospace.",
              "notifications" => "Notifications",
              "push_title" => "Notifications while the app is closed",
              "push_loading" => "loading…",
              "push_test" => "send a test",
              "push_test_title" => "Send one test notification to this device",
              "push_note" => "Tell this device when the app is closed: a reminder, a finished answer, or a subagent reporting in. Permission is asked when the button is pressed."
            },
            "presets" => {
              "none" => "no presets yet",
              "count" => "%{count} presets",
              "remove" => "Remove this preset",
              "temperature" => "Temperature",
              "max_tokens" => "Max tokens",
              "reasoning" => "Reasoning",
              "placeholder" => "default",
              "default" => "Default",
              "new" => "New preset",
              "name_placeholder" => "preset name",
              "model" => "Model",
              "choose_model" => "Choose a model",
              "new_note" => "Name a row and pick its model, then Save. Several at once is fine.",
              "default_preset" => "Default preset",
              "follow_config" => "Follow config.yml",
              "follow_config_note" => "For new sessions. Choose \"Follow config.yml\" to use the value in the file."
            },
            "subagents" => {
              "none" => "nothing configured yet",
              "count" => "%{count} personas",
              "model" => "Model",
              "thinking" => "Thinking",
              "default" => "Default"
            },
            "instagram" => {
              "none" => "not connected yet",
              "count" => "%{count} accounts connected",
              "app_id" => "App ID",
              "app_id_placeholder" => "from the Meta App",
              "app_secret" => "App Secret",
              "clear_secret" => "Remove the App Secret from the database",
              "redirect_uri" => "Redirect URI",
              "redirect_note" => "Register it in the Meta App, Facebook Login, Valid OAuth Redirect URIs. It must be HTTPS (localhost may use HTTP).",
              "accounts" => "Connected accounts",
              "persona" => "Persona",
              "empty" => "Nothing yet. Type \"connect ke instagram\" in the chat to start.",
              "default_mark" => "(default)",
              "disconnect_all" => "Disconnect every Instagram account of this persona",
              "linkable_note" => "Already connected under another persona; tick to link it to this persona without OAuth:"
            },
            "footer" => {
              "refresh_models" => "Refresh the model list",
              "back_to_chat" => "Back to the conversation"
            }
          }
        },
        # The card Telegram shows: what each slash command answers with, the
        # buttons on a confirmation, and the one live status line. The emoji
        # stay inside the values because the mark is part of how a reply reads
        # in a chat list, and a key that dropped it would be a different reply.
        "telegram" => {
          "start" => "👋 Welcome to Rubot!\n\nI'm your AI assistant. Send me any message and I'll help you out.\n\nUse /help to see available commands.",
          "new_session" => "✨ Started a new session. Previous conversation has been cleared.",
          "stop" => {
            "stopped" => "⏹️ Stopped the running task.",
            "nothing" => "ℹ️ Nothing is running."
          },
          # The prefix every rescue clause in this channel answers with.
          "error" => "❌ Error: %{message}",
          "truncated" => "… (truncated)",
          "help" => {
            "header" => "📖 Help | %{bot_name}",
            "lead" => "Just send me a message and I'll do my best to help. While a task is still running, a plain message steers it instead of waiting behind it.",
            "commands" => "Built-in commands:\n/start - Start the bot\n/new - Clear chat and start a new session\n/stop - Stop the task that is running\n/compact - Summarize older messages to free context\n/repin - Rebuild the system prompt on the next message (picks up memory and skills, costs one uncached request)\n/help - Show this help message\n/info - Show agent info\n/model - Show current model preset\n/model <preset> - Switch preset for this session\n/models - List model presets\n/preset - Manage model presets\n/preset set <name> <model> - Create/update a preset\n/preset default <name> - Preset for new sessions\n/preset models - List models supported by the provider\n/use_model <preset> - Alias for /model <preset>\n/persona - Setup persona for this forum topic\n/persona show - Show this topic's persona\n/persona reset - Remove this topic's persona\n/cancel - Cancel the persona setup\n/skills - List available skills\n/memory - Show persistent memory\n/soul - Show bot personality\n/agents - Show agent rules\n/cron - List scheduled cron jobs\n/context - Context usage, cache hit rate, and estimated cost\n/usage - OpenCode Go subscription usage\n/cron delete <id> - Delete a cron job\n/use <skill> - Force a skill for the next message\n/unuse - Clear the forced skill\n/auto on|off - Run non-destructive actions without asking (remembered)"
          },
          "info" => {
            "header" => "ℹ️ Agent Info"
          },
          "context" => {
            "header" => "📊 **Context**",
            "model" => "Model: `%{model}` (%{provider})",
            "window" => "%{used} / %{window} token (%{percent}%)",
            "no_window" => "%{used} token (window unknown)",
            "used" => "Context: %{context}",
            "messages" => "Messages: %{messages} | Requests: %{requests}",
            "tokens" => "Tokens: %{prompt} in / %{completion} out",
            "cache" => "Cache: %{cached} cached total (hit rate %{hit} on the last request)",
            "re_read" => "Re-read: %{tokens} paid in full",
            "cost" => "Estimated cost: `$%{total}`%{bound} (input $%{input}, cache read $%{cached_input}, cache write $%{cache_creation}, output $%{output})%{source}",
            "bound" => " (upper bound)",
            "saved" => "Saved: `$%{saved}` from %{tokens} cached tokens",
            "cost_missing" => "Estimated cost: not available yet (set `pricing` in the config.yml preset)"
          },
          "skills" => {
            "header" => "📚 Available Skills (%{count})",
            "none" => "📚 Skills\n\nNo skills installed.\n\nPlace skills in the workspace `skills/` directory.",
            "list_empty" => "No skills installed.",
            "list_none_enabled" => "No skills are switched on for this persona."
          },
          "memory" => {
            "header" => "🧠 Memory",
            "disabled" => "🧠 Memory is not enabled (no workspace configured)."
          },
          "soul" => {
            "header" => "🧬 Soul",
            "disabled" => "🧬 No soul file (SOUL.md) found in the workspace."
          },
          "agents" => {
            "header" => "📋 Agent Rules",
            "disabled" => "📋 No AGENTS.md found in the workspace."
          },
          "use" => {
            "usage" => "⚠️ Usage: /use <skill-name>\n\nAvailable skills:\n%{skills}",
            "refused" => "🚫 Skill '%{name}' is switched off for this persona.\n\nTurn it back on from the persona's skills list.",
            "applied" => "✅ Skill '%{name}' will be used for the next message.",
            "missing" => "❌ Skill '%{name}' not found or not enabled.\n\nAvailable skills:\n%{skills}",
            "cleared" => "✅ Forced skill cleared.",
            "none" => "ℹ️ No forced skill is set."
          },
          "auto" => {
            "usage" => "Usage: /auto on|off (no argument flips it).",
            "on" => "⚡ Auto mode on — non-destructive actions run without asking.\nDestructive patterns (rm -rf /, mkfs, dd onto a device, …) are still refused.",
            "off" => "🛑 Auto mode off — every dangerous action asks first."
          },
          "repin" => {
            "missing" => "ℹ️ The prompt is not pinned yet, so the next message already rebuilds it from the newest memory and skills.",
            "rebuilt" => "🧠 The prompt is rebuilt on the next message — memory, skills and AGENTS.md that changed come along.\n\nThe cost: the next request pays in full (the prefix changes, so the cache is dropped once)."
          },
          "preset" => {
            "header" => "🧠 **Model Presets**",
            "empty" => "🧠 No model presets yet.\n\nCreate one with:\n`/preset set fast deepseek-v4-pro temperature=0.2`",
            "list_footer" => "\n\nSwitch this session: `/model <preset>`\nManage: `/preset set|default|delete|models`",
            "missing" => "❌ Model preset `%{name}` does not exist.\n\n*Presets available:*\n%{list}",
            "switched" => "✅ This session now uses preset **%{name}** — model `%{model}`.\n_Persists until /new._",
            "switch_failed" => "❌ Failed to switch to preset `%{name}`.",
            "show_missing" => "❌ Preset `%{name}` does not exist.",
            "set_usage" => "⚠️ Usage: `/preset set <name> [model] [temperature=0.2] [max_tokens=4096]`\n\nSee the models available with `/preset models`.",
            "no_config" => "❌ The config is not available.",
            "set_needs_model" => "⚠️ Preset `%{name}` has no model yet. Include a model id: `/preset set %{name} <model>`.",
            "unknown_model" => "❌ Model `%{model}` is not in the provider catalog or config.yml.\n\nCheck `/preset models`.",
            "saved" => "✅ Preset **%{name}** saved.\n\n%{detail}",
            "saved_active" => "\n\n_This session uses that preset, so the change applies at once._",
            "save_failed" => "❌ Failed to save the preset: %{message}",
            "default_none" => "🧠 No named default preset yet. New sessions use the preset **%{name}** (`%{model}`).\n\nSet one with `/preset default <name>`, or `/preset default default` to go back to the config model.",
            "default_set" => "✅ Default preset for **new sessions**: **%{name}** (`%{model}`).\n\nThe session running now is unchanged; use `/model %{name}`.",
            "default_config" => "✅ Back to the config model: `%{model}`.\n\nNew sessions will use this preset.",
            "default_failed" => "❌ Failed to save the default preset: %{message}",
            "deleted" => "🗑️ Preset **%{name}** deleted.\n\nNew sessions use the preset **%{primary}**.",
            "delete_failed" => "❌ Failed to delete the preset: %{message}",
            "models_empty" => "🧠 No model matches. The provider catalog may not be available yet; models from the config still work.",
            "models_header" => "🧠 **Models available (%{count})**",
            "models_hint" => "\n\nCreate a preset: `/preset set <name> <id>`",
            "models_more" => "\n… and %{count} more",
            "detail" => {
              "header" => "🧠 **Preset: %{name}**",
              "model" => "Model: `%{model}`",
              "provider" => "Provider: `%{provider}`",
              "max_tokens" => "Max tokens: `%{value}`",
              "temperature" => "Temperature: `%{value}`",
              "reasoning" => "Reasoning effort: `%{value}`",
              "primary" => "Primary/default: yes"
            },
            "usage" => "🧠 **Usage of /preset**\n\n/preset — list presets\n/preset show <name> — details\n/preset set <name> <model> [temperature=0.2] [max_tokens=4096] [provider=openai] [api_base=...] [reasoning_effort=high]\n/preset default <name|default> — the preset for new sessions\n/preset delete <name>\n/preset models [filter] — the models the provider supports\n\nSwitch this session's preset: /model <name>"
          },
          # The live card: one line of literal state while a request works.
          "status" => {
            "step" => " · step %{step} · %{elapsed}",
            "subagents" => "⟡ %{count} subagents running",
            "subagent_one" => "⟡ 1 subagent running",
            "stop_hint" => "/stop to stop it"
          }
        }
      },
      "id" => {
        "thinking" => {
          "live" => "Berpikir…",
          "done" => "Berpikir %{duration}"
        },
        "compaction" => {
          "running" => "Merangkum percakapan…",
          "failed" => "Pemadatan gagal",
          "done" => "Meringkas %{count} pesan · ~%{before} → ~%{after} token",
          "empty" => "Belum ada yang perlu diringkas: percakapan masih terlalu pendek atau ringkasan gagal dibuat.",
          "note" => "Percakapan berhasil diringkas. Baris penandanya ada di bawah, di tempat compaction terjadi.",
          "row_title" => "Ringkasan otomatis: percakapan lama diringkas untuk mengosongkan konteks",
          "row_done" => "Konteks diringkas.",
          "row_detail" => "%{before} → %{after} token",
          "complete" => "Compact selesai.",
          "title" => "Compact selesai",
          "busy" => "Turn masih berjalan. Ringkas setelah selesai: percakapan yang sedang berjalan tidak boleh ikut diringkas.",
          "error" => "Ringkasan gagal. Coba lagi sebentar.",
          "summarized" => "Pesan diringkas: %{count}",
          "kept" => "Pesan dipertahankan: %{count}",
          "context" => "Perkiraan konteks: ~%{before} → ~%{after} token"
        },
        "footer" => {
          "turn" => "%{duration} giliran (total waktu %{total} · %{count} %{turns})",
          "turn_one" => "giliran",
          "turn_other" => "giliran"
        },
        "status" => {
          "working" => "bekerja",
          "cancelling" => "membatalkan",
          "cancels" => "esc membatalkan",
          "empty_message" => "Tidak ada yang dikirim.",
          "stop_requested" => "Permintaan berhenti dikirim."
        },
        "tool" => {
          "operation_unknown" => "%{prefix}: %{operation}",
          "name" => {
            "memory" => "Memori",
            "cron" => "Tugas terjadwal",
            "loop" => "Loop",
            "instagram" => "Instagram"
          },
          "place" => {
            "here" => "ini",
            "directory" => "direktori ini",
            "file" => "berkas",
            "files" => "%{count} berkas",
            "in" => " di %{target}",
            "to" => " ke %{target}",
            "on" => " pada %{target}"
          },
          "wait" => {
            "seconds" => "%{count} detik",
            "minutes" => "%{count} menit",
            "minutes_seconds" => "%{minutes} menit %{seconds} detik",
            "hours" => "%{count} jam",
            "hours_minutes" => "%{hours} jam %{minutes} menit",
            "days" => "%{count} hari",
            "days_hours" => "%{days} hari %{hours} jam"
          },
          "shell" => {
            "command" => "Menjalankan perintah di terminal",
            "directory" => "Menampilkan isi direktori %{target}",
            "read" => "Membaca isi %{target}",
            "read_follow" => "Melihat log secara langsung",
            "grep" => "Mencari %{pattern} di dalam berkas",
            "grep_bare" => "Mencari sesuatu di dalam berkas",
            "find" => "Mencari berkas%{where}",
            "mkdir" => "Membuat direktori%{where}",
            "remove" => "Menghapus %{target}",
            "move" => "Memindahkan %{from}%{to}",
            "copy" => "Menyalin %{from}%{to}",
            "touch" => "Membuat berkas%{where}",
            "chmod" => "Mengubah izin%{where}",
            "count_lines" => "Menghitung baris%{where}",
            "download" => "Mengambil isi halaman %{url}",
            "processes" => "Melihat proses yang sedang berjalan",
            "kill" => "Menghentikan proses",
            "date" => "Menampilkan tanggal dan waktu",
            "sleep" => "Menunggu %{duration}",
            "sleep_brief" => "Menunggu sebentar",
            "sleep_unbounded" => "Menunggu tanpa batas",
            "locate" => "Mencari lokasi perintah %{command}",
            "echo" => "Menuliskan teks pendek",
            "remote" => "Menghubungi server lain",
            "database" => "Membuka basis data",
            "tests" => "Menjalankan test",
            "style" => "Memeriksa gaya kode",
            "script" => "Menjalankan skrip %{language}%{where}",
            "script_bare" => "Menjalankan %{language}",
            "rake" => "Menjalankan tugas rake",
            "migrate" => "Menjalankan migrasi basis data",
            "go" => "Menjalankan perintah go",
            "go_build" => "Membangun program",
            "go_run" => "Menjalankan program",
            "docker" => "Menjalankan docker %{command}",
            "archive" => "Mengemas atau membuka berkas",
            "service" => "Mengatur layanan sistem"
          },
          "git" => {
            "status" => "Memeriksa status git",
            "diff" => "Melihat perubahan yang belum disimpan",
            "log" => "Melihat riwayat commit",
            "add" => "Menandai perubahan untuk di-commit",
            "commit" => "Menyimpan perubahan ke git",
            "push" => "Mengirim commit ke remote",
            "pull" => "Mengambil pembaruan dari remote",
            "checkout" => "Berpindah branch%{where}",
            "branch" => "Melihat daftar branch",
            "stash" => "Menyimpan perubahan sementara",
            "show" => "Melihat rincian satu commit",
            "clone" => "Mengunduh salinan repositori",
            "other" => "Mengurus repositori git"
          },
          "package" => {
            "install" => "Memasang dependensi",
            "test" => "Menjalankan test",
            "run" => "Menjalankan skrip proyek",
            "build" => "Membangun proyek",
            "gem" => "Mengurus gem",
            "other" => "Mengurus dependensi"
          },
          "file" => {
            "read" => "Membaca isi %{target}",
            "write" => "Menulis berkas %{target}",
            "edit" => "Mengubah isi %{target}",
            "append" => "Menambahkan isi ke %{target}",
            "delete" => "Menghapus %{target}",
            "list" => "Menampilkan isi direktori %{target}",
            "info" => "Memeriksa %{target}"
          },
          "memory" => {
            "read" => "Mengingat kembali catatan",
            "append" => "Mencatat satu hal ke ingatan",
            "update_section" => "Merapikan satu bagian catatan"
          },
          "cron" => {
            "add" => "Menjadwalkan tugas berkala",
            "list" => "Melihat daftar tugas terjadwal",
            "detail" => "Melihat satu tugas terjadwal",
            "remove" => "Membatalkan satu tugas",
            "enable" => "Mengaktifkan satu tugas",
            "disable" => "Menonaktifkan satu tugas"
          },
          "loop" => {
            "status" => "Melihat keadaan satu loop",
            "list" => "Melihat daftar loop",
            "pause" => "Menghentikan loop sementara",
            "resume" => "Melanjutkan loop yang berhenti",
            "stop" => "Menghentikan loop",
            "undo" => "Membatalkan iterasi terakhir",
            "start" => "Memulai loop: %{goal}",
            "start_bare" => "Memulai loop baru"
          },
          "instagram" => {
            "connect" => "Menyiapkan sambungan Instagram",
            "status" => "Memeriksa akun Instagram",
            "schedule" => "Menjadwalkan unggahan Instagram",
            "publish" => "Mengunggah ke Instagram",
            "posts" => "Melihat daftar unggahan Instagram",
            "cancel" => "Membatalkan unggahan Instagram",
            "link" => "Menautkan akun Instagram",
            "disconnect" => "Melepas akun Instagram",
            "other" => "Mengurus Instagram"
          },
          "subagent_results" => "Membaca hasil kerja subagent",
          "notify" => "Bersiap memberi kabar begitu selesai",
          "send" => {
            "none" => "Mengirim berkas",
            "one" => "Mengirim satu berkas",
            "many" => "Mengirim %{count} berkas"
          },
          "search" => {
            "files" => "Mencari berkas",
            "code" => "Mencari di dalam kode",
            "files_named" => "Mencari berkas bernama \"%{pattern}\"",
            "code_for" => "Mencari \"%{pattern}\" di dalam kode"
          },
          "fetch" => "Membuka sebuah halaman",
          "fetch_page" => "Membuka halaman %{url}",
          "delegate" => "Meminta bantuan subagent",
          "delegate_named" => "Meminta bantuan %{agent}"
        },
        "settings" => {
          "language" => {
            "label" => "Bahasa",
            "note" => "Bahasa yang dipakai Rubot: baris tool, blok thinking, dan baris status. Berlaku untuk semua kanal di pemasangan ini.",
            "en" => "English",
            "id" => "Bahasa Indonesia",
            "unknown" => "Bahasa %{value} tidak dikenal: pilih %{choices}."
          }
        },
        "web" => {
          "settings" => {
            "title" => "rubot · pengaturan",
            "back" => "kembali",
            "topbar" => "pengaturan",
            "saved" => "Tersimpan",
            "save" => "Simpan",
            "heading" => "Pengaturan",
            "lead" => "Koneksi dan model berlaku untuk semua persona. Tema, font, dan notifikasi berlaku di perangkat ini, dan tersimpan begitu ditekan.",
            "no_archive" => "Arsip sesi belum terbuka, jadi belum ada tempat untuk menyimpan.",
            "tabs" => {
              "label" => "Bagian pengaturan",
              "connection" => "Koneksi",
              "appearance" => "Tampilan",
              "presets" => "Preset model",
              "subagents" => "Subagent",
              "instagram" => "Instagram"
            },
            "field" => {
              "key_stored" => "sudah tersimpan, kosongkan untuk tidak mengubah",
              "key_missing" => "belum ada"
            },
            "connection" => {
              "provider" => "Provider",
              "api_key" => "API key",
              "key_from_archive" => "Tersimpan di database pemasangan. Centang untuk kembali ke config.yml.",
              "clear_key" => "Hapus kunci dari database",
              "no_key" => "Tanpa kunci, hanya provider lokal seperti ollama yang bisa menjawab.",
              "default_model" => "Model default",
              "auxiliary_model" => "Model auxiliary",
              "auxiliary_blank" => "Ikut model default",
              "auxiliary_note" => "Untuk pekerjaan di belakang layar: merangkum dan menamai sesi.",
              "subagent_model" => "Model subagent",
              "subagent_blank" => "Ikuti preset subagent (flash)",
              "subagent_note" => "Untuk semua subagent. Kosongkan untuk memakai preset bawaan."
            },
            "appearance" => {
              "note" => "perangkat ini, tersimpan begitu ditekan",
              "theme" => "Tema",
              "font" => "Font",
              "font_note" => "Serif adalah bawaan. Georgia dan Palatino memakai huruf milik perangkat, jadi tampilannya bisa sedikit berbeda. Nama mesin tetap monospace.",
              "notifications" => "Notifikasi",
              "push_title" => "Notifikasi saat app sedang ditutup",
              "push_loading" => "memuat…",
              "push_test" => "kirim tes",
              "push_test_title" => "Kirim satu notifikasi percobaan ke perangkat ini",
              "push_note" => "Kabari perangkat ini saat app tertutup: pengingat, balasan yang selesai, atau subagent yang melapor. Izin diminta saat tombolnya ditekan."
            },
            "presets" => {
              "none" => "belum ada preset",
              "count" => "%{count} preset",
              "remove" => "Hapus preset ini",
              "temperature" => "Temperature",
              "max_tokens" => "Max tokens",
              "reasoning" => "Reasoning",
              "placeholder" => "bawaan",
              "default" => "Bawaan",
              "new" => "Preset baru",
              "name_placeholder" => "nama preset",
              "model" => "Model",
              "choose_model" => "Pilih model",
              "new_note" => "Isi nama dan pilih model pada baris yang ingin ditambahkan, lalu Simpan. Bisa beberapa sekaligus.",
              "default_preset" => "Preset default",
              "follow_config" => "Ikut config.yml",
              "follow_config_note" => "Untuk sesi baru. Pilih \"Ikut config.yml\" untuk memakai nilai dari berkas."
            },
            "subagents" => {
              "none" => "belum ada yang diatur",
              "count" => "%{count} persona",
              "model" => "Model",
              "thinking" => "Thinking",
              "default" => "Bawaan"
            },
            "instagram" => {
              "none" => "belum terhubung",
              "count" => "%{count} akun terhubung",
              "app_id" => "App ID",
              "app_id_placeholder" => "dari Meta App",
              "app_secret" => "App Secret",
              "clear_secret" => "Hapus App Secret dari database",
              "redirect_uri" => "Redirect URI",
              "redirect_note" => "Daftarkan di Meta App, Facebook Login, Valid OAuth Redirect URIs. Harus HTTPS (localhost boleh HTTP).",
              "accounts" => "Akun terhubung",
              "persona" => "Persona",
              "empty" => "Belum ada. Ketik \"connect ke instagram\" di chat untuk mulai.",
              "default_mark" => "(default)",
              "disconnect_all" => "Putuskan semua akun Instagram persona ini",
              "linkable_note" => "Sudah terhubung di persona lain, centang untuk link ke persona ini tanpa OAuth:"
            },
            "footer" => {
              "refresh_models" => "Refresh daftar model",
              "back_to_chat" => "Kembali ke percakapan"
            }
          }
        },
        "telegram" => {
          "start" => "👋 Selamat datang di Rubot!\n\nSaya asisten AI kamu. Kirim pesan apa saja dan saya bantu.\n\nKetik /help untuk melihat perintah yang tersedia.",
          "new_session" => "✨ Sesi baru dimulai. Percakapan sebelumnya sudah dibersihkan.",
          "stop" => {
            "stopped" => "⏹️ Tugas yang berjalan dihentikan.",
            "nothing" => "ℹ️ Tidak ada yang sedang berjalan."
          },
          "error" => "❌ Error: %{message}",
          "truncated" => "… (dipotong)",
          "help" => {
            "header" => "📖 Bantuan | %{bot_name}",
            "lead" => "Kirim saja pesan dan saya bantu sebaik mungkin. Saat tugas masih berjalan, pesan biasa mengarahkan tugas itu, bukan menunggu di belakangnya.",
            "commands" => "Perintah bawaan:\n/start - Mulai bot\n/new - Bersihkan chat dan mulai sesi baru\n/stop - Hentikan tugas yang sedang berjalan\n/compact - Ringkas pesan lama untuk menghemat konteks\n/repin - Bangun ulang system prompt pada pesan berikutnya (memory dan skill terbaru ikut, biayanya satu request tanpa cache)\n/help - Tampilkan pesan bantuan ini\n/info - Tampilkan info agen\n/model - Tampilkan preset model yang aktif\n/model <preset> - Ganti preset untuk sesi ini\n/models - Daftar preset model\n/preset - Kelola preset model\n/preset set <nama> <model> - Buat atau ubah preset\n/preset default <nama> - Preset untuk sesi baru\n/preset models - Daftar model yang didukung provider\n/use_model <preset> - Alias untuk /model <preset>\n/persona - Siapkan persona untuk forum topic ini\n/persona show - Tampilkan persona topic ini\n/persona reset - Hapus persona topic ini\n/cancel - Batalkan penyiapan persona\n/skills - Daftar skill yang tersedia\n/memory - Tampilkan memory tetap\n/soul - Tampilkan kepribadian bot\n/agents - Tampilkan aturan agen\n/cron - Daftar cron job terjadwal\n/context - Pemakaian konteks, hit rate cache, dan perkiraan biaya\n/usage - Pemakaian langganan OpenCode Go\n/cron delete <id> - Hapus cron job\n/use <skill> - Paksa satu skill untuk pesan berikutnya\n/unuse - Bersihkan skill paksa\n/auto on|off - Jalankan aksi non-destruktif tanpa bertanya (diingat)"
          },
          "info" => {
            "header" => "ℹ️ Info Agen"
          },
          "context" => {
            "header" => "📊 **Konteks Sesi**",
            "model" => "Model: `%{model}` (%{provider})",
            "window" => "%{used} / %{window} token (%{percent}%)",
            "no_window" => "%{used} token (window tidak diketahui)",
            "used" => "Konteks: %{context}",
            "messages" => "Pesan: %{messages} | Request: %{requests}",
            "tokens" => "Token: %{prompt} in / %{completion} out",
            "cache" => "Cache: %{cached} cached total (hit rate %{hit} pada request terakhir)",
            "re_read" => "Re-read: %{tokens} token dibayar penuh",
            "cost" => "Estimasi biaya: `$%{total}`%{bound} (input $%{input}, cache read $%{cached_input}, cache write $%{cache_creation}, output $%{output})%{source}",
            "bound" => " (batas atas)",
            "saved" => "Dihemat: `$%{saved}` dari %{tokens} token cache",
            "cost_missing" => "Estimasi biaya: belum tersedia (set `pricing` di preset config.yml)"
          },
          "skills" => {
            "header" => "📚 Skill Tersedia (%{count})",
            "none" => "📚 Skills\n\nBelum ada skill yang terpasang.\n\nTaruh skill di direktori `skills/` workspace.",
            "list_empty" => "Belum ada skill yang terpasang.",
            "list_none_enabled" => "Tidak ada skill yang aktif untuk persona ini."
          },
          "memory" => {
            "header" => "🧠 Memory",
            "disabled" => "🧠 Memory tidak aktif (workspace belum diatur)."
          },
          "soul" => {
            "header" => "🧬 Soul",
            "disabled" => "🧬 Tidak ada berkas soul (SOUL.md) di workspace."
          },
          "agents" => {
            "header" => "📋 Aturan Agen",
            "disabled" => "📋 Tidak ada AGENTS.md di workspace."
          },
          "use" => {
            "usage" => "⚠️ Penggunaan: /use <nama-skill>\n\nSkill tersedia:\n%{skills}",
            "refused" => "🚫 Skill '%{name}' dimatikan untuk persona ini.\n\nNyalakan lagi dari daftar skill persona.",
            "applied" => "✅ Skill '%{name}' akan dipakai untuk pesan berikutnya.",
            "missing" => "❌ Skill '%{name}' tidak ditemukan atau tidak aktif.\n\nSkill tersedia:\n%{skills}",
            "cleared" => "✅ Skill paksa dibersihkan.",
            "none" => "ℹ️ Tidak ada skill paksa yang aktif."
          },
          "auto" => {
            "usage" => "Penggunaan: /auto on|off (tanpa argumen membaliknya).",
            "on" => "⚡ Mode auto aktif: aksi non-destruktif jalan tanpa bertanya.\nPola destruktif (rm -rf /, mkfs, dd ke device, …) tetap ditolak.",
            "off" => "🛑 Mode auto mati: setiap aksi berbahaya bertanya dulu."
          },
          "repin" => {
            "missing" => "ℹ️ Prompt belum di-pin, jadi pesan berikutnya memang sudah membangunnya dari memory dan skill terbaru.",
            "rebuilt" => "🧠 Prompt akan dibangun ulang pada pesan berikutnya — memory, skill, dan AGENTS.md yang berubah ikut masuk.\n\nOngkosnya: request berikutnya membayar penuh (prefix berubah, jadi cache sekali hangus)."
          },
          "preset" => {
            "header" => "🧠 **Preset Model**",
            "empty" => "🧠 Belum ada model preset.\n\nBuat dengan:\n`/preset set fast deepseek-v4-pro temperature=0.2`",
            "list_footer" => "\n\nGanti untuk sesi ini: `/model <preset>`\nKelola: `/preset set|default|delete|models`",
            "missing" => "❌ Model preset `%{name}` tidak ada.\n\n*Preset tersedia:*\n%{list}",
            "switched" => "✅ Sesi ini sekarang memakai preset **%{name}** — model `%{model}`.\n_Bertahan sampai /new._",
            "switch_failed" => "❌ Gagal mengganti preset ke `%{name}`.",
            "show_missing" => "❌ Preset `%{name}` tidak ada.",
            "set_usage" => "⚠️ Penggunaan: `/preset set <nama> [model] [temperature=0.2] [max_tokens=4096]`\n\nLihat model yang tersedia dengan `/preset models`.",
            "no_config" => "❌ Config tidak tersedia.",
            "set_needs_model" => "⚠️ Preset `%{name}` belum punya model. Sertakan model id: `/preset set %{name} <model>`.",
            "unknown_model" => "❌ Model `%{model}` tidak ada di katalog provider atau config.yml.\n\nCek `/preset models`.",
            "saved" => "✅ Preset **%{name}** disimpan.\n\n%{detail}",
            "saved_active" => "\n\n_Sesi ini memakai preset tersebut; perubahannya langsung diterapkan._",
            "save_failed" => "❌ Gagal menyimpan preset: %{message}",
            "default_none" => "🧠 Belum ada preset default bernama. Sesi baru memakai preset **%{name}** (`%{model}`).\n\nAtur dengan `/preset default <nama>`, atau `/preset default default` untuk kembali ke model config.",
            "default_set" => "✅ Preset default untuk **sesi baru**: **%{name}** (`%{model}`).\n\nSesi yang sedang berjalan tidak diubah; gunakan `/model %{name}`.",
            "default_config" => "✅ Default kembali ke model config: `%{model}`.\n\nSesi baru akan memakai preset ini.",
            "default_failed" => "❌ Gagal menyimpan default preset: %{message}",
            "deleted" => "🗑️ Preset **%{name}** dihapus.\n\nSesi baru memakai preset **%{primary}**.",
            "delete_failed" => "❌ Gagal menghapus preset: %{message}",
            "models_empty" => "🧠 Tidak ada model yang cocok. Katalog provider mungkin belum tersedia; model dari config tetap bisa dipakai.",
            "models_header" => "🧠 **Model tersedia (%{count})**",
            "models_hint" => "\n\nBuat preset: `/preset set <nama> <id>`",
            "models_more" => "\n… dan %{count} lainnya",
            "detail" => {
              "header" => "🧠 **Preset: %{name}**",
              "model" => "Model: `%{model}`",
              "provider" => "Provider: `%{provider}`",
              "max_tokens" => "Max tokens: `%{value}`",
              "temperature" => "Temperature: `%{value}`",
              "reasoning" => "Reasoning effort: `%{value}`",
              "primary" => "Primary/default: ya"
            },
            "usage" => "🧠 **Penggunaan /preset**\n\n/preset — daftar preset\n/preset show <nama> — detail\n/preset set <nama> <model> [temperature=0.2] [max_tokens=4096] [provider=openai] [api_base=...] [reasoning_effort=high]\n/preset default <nama|default> — preset untuk sesi baru\n/preset delete <nama>\n/preset models [filter] — model yang didukung provider\n\nGanti preset sesi ini: /model <nama>"
          },
          "status" => {
            "step" => " · langkah %{step} · %{elapsed}",
            "subagents" => "⟡ %{count} subagent aktif",
            "subagent_one" => "⟡ 1 subagent aktif",
            "stop_hint" => "/stop untuk menghentikan"
          }
        }
      }
    }.freeze

    class << self
      # The language everything drawn from here on is written in.
      def locale
        @locale || DEFAULT_LOCALE
      end

      def locale=(value)
        @locale = normalize!(value)
      end

      # Run a block in another language and put the old one back, even when the
      # block raises. The seam a test uses, and the way a page that speaks one
      # language while the install speaks another stays honest.
      def with_locale(value)
        previous = locale
        self.locale = value
        yield
      ensure
        @locale = previous
      end

      # The one translation function. `%{name}` in the entry is filled from the
      # keyword arguments; an unknown key raises rather than returning the key,
      # because a dotted key on screen is not a label.
      def t(key, locale: nil, **vars)
        target = locale ? normalize!(locale) : self.locale
        entry = lookup(target, key) || lookup(DEFAULT_LOCALE, key)
        raise MissingTranslation, "no translation for #{key.inspect} in #{LOCALES.join('/')}" if entry.nil?

        interpolate(entry, vars)
      end

      alias translate t

      # The locale a config asks for, or nil when it asks for nothing (so the
      # caller keeps the default). A value that is not a language raises; see
      # Config#bahasa, which is the only caller that faces a config file.
      def normalize(value)
        text = value.to_s.strip.downcase
        return nil if text.empty?

        LOCALES.include?(text) ? text : nil
      end

      def normalize!(value)
        normalized = normalize(value)
        return normalized if normalized

        raise UnknownLocale,
              "unknown language #{value.to_s.inspect} for `#{CONFIG_KEY}`: use one of #{LOCALES.join(', ')}"
      end

      def valid_locale?(value)
        !normalize(value).nil?
      end

      # Every leaf key of one language, dotted, sorted. The parity check and the
      # settings form both read the dictionary through this.
      def keys(locale: DEFAULT_LOCALE)
        flatten(DICTIONARY.fetch(normalize!(locale).to_s, {}))
      end

      # Keys one language has and another does not, in either direction. Empty
      # for a dictionary whose two halves agree.
      def missing_keys(left: "en", right: "id")
        (keys(locale: left) - keys(locale: right)) | (keys(locale: right) - keys(locale: left))
      end

      private

      def lookup(locale_name, key)
        key.to_s.split(".").reduce(DICTIONARY[locale_name]) do |node, part|
          return nil unless node.is_a?(Hash)

          node[part]
        end
      end

      def interpolate(entry, vars)
        return entry unless entry.is_a?(String) && !vars.empty?

        entry.gsub(PLACEHOLDER) { vars.fetch(Regexp.last_match(1).to_sym, "").to_s }
      end

      def flatten(node, prefix = "")
        return [ prefix ] unless node.is_a?(Hash)

        node.flat_map do |part, value|
          flatten(value, prefix.empty? ? part.to_s : "#{prefix}.#{part}")
        end
      end
    end
  end
end
