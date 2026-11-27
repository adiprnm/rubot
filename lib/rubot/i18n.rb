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
        # The confirmation that closes a list of questions. It is the tool's,
        # not a channel's: every surface renders the same two choices, and the
        # labels travel with the question as its options.
        "ask" => {
          "confirm" => {
            "question" => "Send these answers?",
            "send" => "Send",
            "send_description" => "Use these answers and carry on",
            "restart" => "Start over",
            "restart_description" => "Ask the questions again from the start"
          }
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
          "skill" => {
            "load" => "Loading the %{name} skill",
            "load_many" => "Loading the %{names} skills",
            "joiner" => " and ",
            "separator" => ", ",
            "label" => "skill"
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
          "delegate_named" => "Asking %{agent} for help",
          "ask" => "Asking: %{question}",
          "ask_plain" => "Asking you a question"
        },
        # What the terminal's slash commands answer with. One group per
        # command family, since the lines a command prints travel together and
        # a translator reads them better side by side than scattered by wording.
        "tui" => {
          "commands" => {
            "available" => "Available commands:",
            "keys" => "Keys:",
            "unknown" => "Unknown command: %{command}.",
            "unknown_hint" => "Type /help for available commands.",
            "stop_requested" => "Stop requested."
          },
          "session" => {
            "cleared" => "Session cleared.",
            "switched" => "Session switched to: %{name}",
            "current" => "Current session: %{id}",
            "model" => "Model: %{model}",
            "browse_hint" => "Type /resume to browse saved sessions.",
            "not_found" => "Session '%{query}' not found.",
            "see_hint" => "Type /resume to see saved sessions.",
            "none" => "No saved sessions yet.",
            "none_hint" => "Conversations are saved as they happen; /resume brings one back later.",
            "other_dirs" => "%{count} conversation(s) from other directories · /resume all",
            "list_title" => "Saved sessions:",
            "messages_unit" => "msgs",
            "resume_hint" => "Resume one with /resume <number> or /resume <id>.",
            "other_dirs_more" => "%{count} more from other directories · /resume all"
          },
          "prompt" => {
            "repinned" => "System prompt will be rebuilt on the next message.",
            "repinned_detail" => "Memory, skills and AGENTS.md changed since this session started are picked up.",
            "repinned_cost" => "Cost: the next request pays in full — the prefix moved, so the cache is gone once.",
            "not_pinned" => "The prompt is not pinned; the next message builds it from the latest files anyway."
          },
          "info" => {
            "title" => "Agent info:"
          },
          "context" => {
            "live" => "live — the request in flight is not in these totals yet"
          },
          # The two tables /help prints. One entry per row of the tables in
          # tui.rb, keyed by the row itself (see Commands#help_slug).
          "help" => {
            "cmd" => {
              "help" => "Show this help message",
              "new" => "Clear conversation and start a new session",
              "stop" => "Stop the task that is running",
              "compact" => "Summarize older messages to free context",
              "repin" => "Rebuild the system prompt on the next message (picks up memory and skills, costs one uncached request)",
              "clear" => "Clear conversation history",
              "session" => "Show current session ID",
              "session_name" => "Switch to a new session",
              "resume" => "Pick a saved session to resume",
              "resume_n_name" => "Resume a saved session",
              "search_kata" => "Search every stored message, including compacted turns",
              "info" => "Show agent info (provider, model, tools)",
              "context" => "Show context usage, cache hit rate, and estimated cost",
              "usage" => "Show OpenCode Go subscription usage",
              "timing" => "Where provider requests spend their time (needs RUBOT_TIMING=1 on launch)",
              "models" => "List the models the provider supports",
              "model" => "Show current active model",
              "use_model_name" => "Switch to a model for this session",
              "tools" => "List available tools",
              "soul" => "Show the bot's soul (SOUL.md)",
              "memory" => "Show persistent memory (MEMORY.md)",
              "agents" => "Show agent rules (AGENTS.md)",
              "delegates" => "List personas available for sub-agent delegation",
              "cron" => "List scheduled cron jobs",
              "web_restart" => "Restart the web channel (bin/rubot web)",
              "auto_on_off" => "Auto mode: run non-destructive actions without asking (remembered)",
              "stream_on_off" => "Toggle streaming output",
              "use_skill" => "Force a specific skill for the next message",
              "unuse" => "Clear the forced skill",
              "quit" => "Exit rubot"
            },
            "key" => {
              "enter" => "Send the prompt, or take the highlighted /command",
              "enter_running" => "Steer the turn that is running instead of waiting",
              "shift_enter" => "Insert a newline (the box grows)",
              "ctrl_g" => "Edit the prompt in $EDITOR, then take it back",
              "tab" => "Complete a /command",
              "up_down" => "Pick a /command, move between lines, or browse history",
              "ctrl_left_right" => "Move the caret one word left or right",
              "esc" => "Cancel the running turn, clear a selection, dismiss the list",
              "pgup_pgdn" => "Scroll the conversation",
              "ctrl_c" => "Quit rubot"
            }
          },
          "model" => {
            "current" => "Current model: %{model} (%{id})",
            "override" => "Session override — cleared on /new.",
            "none" => "No models available.",
            "none_hint" => "The provider returned no model catalog, and config.yml has no models.",
            "no_match" => "No model matches '%{filter}'.",
            "list_title" => "Models supported by %{provider}",
            "list_header" => "Models supported by %{provider}:",
            "provider_fallback" => "the provider",
            "catalog_failed" => "Could not read the model catalog: %{message}",
            "usage" => "Usage: /use-model <model-name>",
            "switched" => "Switched to model: %{model}",
            "switched_label" => "Switched to model: %{model} (%{label})",
            "provider" => "Provider: %{provider}",
            "session_only" => "Persists for this session (cleared on /new).",
            "not_found" => "Model '%{name}' not found in config.yml or the provider catalog."
          },
          "tools" => {
            "title" => "Available tools:"
          },
          "soul" => {
            "title" => "Soul (SOUL.md):",
            "none" => "No soul file (SOUL.md) found in workspace."
          },
          "memory" => {
            "global" => "Memory — global: %{path}",
            "workspace" => "Memory — this workspace: %{path}",
            "title" => "Memory (MEMORY.md):",
            "none" => "Memory not available (no workspace configured)."
          },
          "agents" => {
            "title" => "Agent rules (AGENTS.md):",
            "none" => "No AGENTS.md found in workspace."
          },
          "cron" => {
            "none" => "Cron tool not available."
          },
          "stream" => {
            "state" => "Streaming %{state}.",
            "on" => "on",
            "off" => "off"
          },
          "skill" => {
            "cleared" => "Forced skill cleared.",
            "none" => "No forced skill is set.",
            "usage" => "Usage: /use <skill-name>",
            "available" => "Available skills: %{skills}",
            "empty" => "(none)",
            "off" => "Skill '%{name}' is switched off for this persona.",
            "off_hint" => "Turn it back on from the persona's skills list.",
            "forced" => "Skill '%{name}' will be used for the next message.",
            "not_found" => "Skill '%{name}' not found or not enabled."
          },
          "web" => {
            "restarted" => "Web server restarted.",
            "restart_failed" => "Web server restart failed."
          },
          "delegates" => {
            "off" => "Delegation is off. Set delegation.enabled: true in config.yml.",
            "none" => "No personas to delegate to yet.",
            "title" => "Delegates (%{count}):",
            "failed" => "Could not list delegates: %{error}"
          },
          "auto" => {
            "usage" => "Usage: /auto on|off (no argument flips it).",
            "on" => "Auto mode on — non-destructive actions run without asking.",
            "on_detail" => "Destructive patterns (rm -rf /, mkfs, dd onto a device, …) are still refused.",
            "off" => "Auto mode off — every dangerous action asks first."
          },
          "search" => {
            "title" => "Search the archive:",
            "hint" => "/search <query> — every stored message, including compacted turns",
            "no_archive" => "The archive is not open, so there is nothing to search.",
            "no_archive_hint" => "Search reads the SQLite archive; without it, conversations are files and /resume lists them.",
            "nothing" => "Nothing matches %{query}.",
            "hits" => "%{count} hit(s) for %{query}:",
            "resume_hint" => "Resume one with /resume <id>."
          }
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
          # The conversation's own chrome: the header that names the persona
          # and the conversation, and the field a person types into. These are
          # drawn on the one page a reader lives in, so they are the first thing
          # a language switch has to move.
          "chathead" => {
            "menu" => "Persona and conversations",
            "rename" => "Rename this conversation",
            "rename_named" => "Rename this conversation: %{name}",
            "name_field" => "Conversation name",
            "save_name" => "Save the name",
            "cancel" => "Cancel"
          },
          # The composer's words live in `title` and `aria-label` rather than in
          # the page: both buttons are icons, so the label is the only place the
          # word exists. `send_waiting` and `send_busy` are what the send button
          # says instead of `send` while it cannot do its usual thing.
          "composer" => {
            "message" => "Message",
            "placeholder" => "Write a message… Enter sends, Shift+Enter starts a new line",
            "send" => "Send",
            "send_busy" => "Send as guidance to the running turn",
            "send_waiting" => "Waiting for the compaction to finish",
            "unquote" => "Remove the quote",
            "stop" => "Stop",
            "stop_pending" => "Stopping…"
          },
          "emoji" => {
            "label" => "Emoji",
            "pick" => "Pick an emoji",
            "search" => "Search emoji",
            "search_placeholder" => "Search emoji…",
            "other" => "Another emoji",
            "other_placeholder" => "Another emoji…"
          },
          # The card that asks before a dangerous action runs. The tool's own
          # name and reason arrive from the turn; the frame around them is here.
          "confirm" => {
            "title" => "Confirm: %{name}",
            "continue" => "Continue",
            "cancel" => "Cancel"
          },
          # The question from the ask_user tool. The option labels come from the
          # model, so only the frame around them is translated.
          "ask" => {
            "custom" => "Other: type your answer",
            "send" => "Send"
          },
          # The archive dialog. Its hint is the same sentence the results pane
          # opens with, so the two share one key rather than drifting apart.
          "search" => {
            "label" => "Search conversations",
            "placeholder" => "Search every conversation…",
            "hint" => "Search every conversation, including the ones no longer in the sidebar.",
            "close" => "Close (esc)",
            "open" => "Search conversations (⌘K)",
            "results" => "Search results",
            "no_match" => "Nothing matches “%{query}”."
          },
          # The persona roster and the two forms that write one: the drawer's
          # leftmost column, the panel that adds a persona and the panel that
          # edits the one already open. A slug is a key and a directory name, so
          # its example stays as it is in both languages.
          "personas" => {
            "rail_label" => "Personas",
            "new" => "New persona",
            "edit" => "Edit persona",
            "slug" => "Slug",
            "slug_placeholder" => "kanyaah",
            "slug_hint" => "slug:",
            "name" => "Name",
            "name_placeholder" => "Kanyaah",
            "default_model" => "Default model",
            "follow_default" => "Use the default",
            "default_thinking" => "Default thinking",
            "system_prompt" => "System prompt",
            "prompt_placeholder" => "What are you a specialist in…",
            "prompt_keep" => "Leave it empty to keep the built-in prompt",
            "create" => "Create",
            "new_session" => "New session",
            "fact_persona" => "persona",
            "fact_model" => "model",
            "fact_session" => "session",
            "empty" => "%{name} has a SOUL, skills and a memory of its own. Everything it runs through a tool is drawn above its answer. A new session starts from an empty conversation, with the same persona."
          },
          # The two lists in the drawer, and the one row each conversation gets.
          # `unread` is the dot's label for a reader who cannot see the dot;
          # `unread_count` is the same news carried by the drawer's handle.
          "sessions" => {
            "pinned" => "Pinned",
            "recent" => "Recent",
            "pin_limit" => "At most 10 pinned sessions per persona",
            "empty_pinned" => "No pinned sessions yet.",
            "empty_recent" => "No sessions yet.",
            "unread" => "unread",
            "unread_count" => "%{count} unread conversations",
            "pin" => "Pin this session",
            "unpin" => "Unpin this session",
            "delete" => "Delete this session",
            "delete_confirm" => "Delete this session? Its whole conversation goes with it.",
            # The name a conversation wears until its first prompt has been
            # saved. A label, not the button that starts one
            # (`web.personas.new_session`), so the two can be worded apart.
            "untitled" => "New session",
            "more" => "Load more"
          },
          # The files a turn sends back. The name is the turn's, the verb is the
          # dictionary's: the card is a button or a link, and what pressing it
          # does has to be said in the reader's language.
          "attachments" => {
            "group" => "Attachments from Rubot",
            "play" => "Play %{name}",
            "download" => "Download %{name}",
            "open" => "Open %{name}",
            "file" => "FILE"
          },
          # What the field answers when a prompt cannot be started. The whole
          # notice is the sentence, drawn above the composer.
          "turn" => {
            "empty_message" => "The message is empty.",
            "busy" => "A turn is still running. Wait a moment, or press Stop.",
            "compacting" => "The conversation is being summarised. Wait a moment, then send again."
          },
          # The mark a rendered block carries: taking it back to the field as
          # context, and how much of the block the chip says it carries.
          "markdown" => {
            "quote_paragraph" => "Quote this paragraph",
            "quote_list" => "Quote this list",
            "list_kind" => "List · %{count} items"
          },
          # The status row, the report it opens, and the facts in that report.
          # The row is three figures whose names live in a tooltip; the report is
          # the same numbers written out, so the two share this namespace.
          "usage" => {
            "row_cost" => "Total cost of this session, cumulative since its first request",
            "row_cache" => "The share of the prompt taken from cache on the last request — not an average over the session",
            "row_context" => "The share of the model's context window the next request will use",
            "sheet" => "Usage",
            "prompt" => "Prompt",
            "repin" => "Rebuild",
            "repin_note" => "Memory, skills and AGENTS.md that change mid-session only come in after a compaction — or here, at the cost of one request with no cache.",
            "facts" => {
              "model" => "model",
              "cost" => "cost",
              "requests" => "requests",
              "messages" => "%{count} messages",
              "tokens" => "tokens",
              "split" => "%{input} in · %{output} out",
              "reasoning" => "%{tokens} reasoning",
              "reread" => "read again",
              "reread_value" => "%{tokens} tokens",
              "reread_title" => "The part of the last request paid at full price: that is what a shift in the prompt's prefix ate into.",
              "cache" => "cache",
              "saved" => "saved",
              "saved_title" => "The difference between the full input price and the cache read price for the tokens that came from cache. Not part of the cost — this is money that did not leave.",
              "cache_history" => "cache history",
              "cache_history_title" => "The cache share of each request, oldest first. A run of 0% means the prompt's prefix keeps changing; a single 0% after a compaction is normal.",
              "context" => "context",
              "unknown" => "unknown",
              "cost_in" => "in %{value}",
              "cost_cache_read" => "cache read %{value}",
              "cost_cache_write" => "cache write %{value}",
              "cost_out" => "out %{value}",
              "cache_from" => "%{tokens} tokens from cache",
              "cache_shares" => "%{last}% last request · %{session}% session average · %{tokens} tokens total"
            }
          },
          # The allowance the provider has left, in a sheet of its own because
          # it is asked of a different party than the report above.
          "quota" => {
            "label" => "Allowance",
            "checking" => "Checking the allowance…",
            "used" => "%{percent}% used",
            "reset_in" => "resets in %{when}",
            # A provider that sells tokens by the drink has no subscription to
            # run out of, and that is not a failure to report as one.
            "unavailable" => "This provider has no subscription allowance; it bills per token.",
            "error" => "The allowance could not be checked — %{error}.",
            "check_failed" => "The allowance could not be checked right now.",
            # The windows a meter measures. `rolling` is the provider's own
            # window and keeps its length, so the label says the hours.
            "meters" => {
              "rolling" => "5 hours",
              "weekly" => "weekly",
              "monthly" => "monthly"
            }
          },
          # The model and the effort a session runs on, under the composer.
          # `thinking` is the name of the setting, not a word to translate.
          "session_settings" => {
            "trigger" => "Model and thinking level of this session: %{model}, %{thinking}",
            "dialog" => "Model and thinking level",
            "search" => "Search models",
            "search_placeholder" => "Search models…",
            "models" => "Model",
            "no_match" => "No model matches.",
            "thinking" => "thinking",
            "choose_model" => "choose a model",
            "count" => "%{count} models"
          },
          # The delegated runs of this conversation, at the same edge as the
          # usage row. `toggle` is the word on the control; `title` heads the
          # panel it opens.
          "subagents" => {
            "title" => "Subagents",
            "toggle" => "subagent",
            "empty" => "No subagents in this conversation yet.",
            "running" => "%{count} subagents running",
            "running_one" => "1 subagent running",
            "failed" => "subagent failed",
            "done" => "subagent finished"
          },
          "loops" => {
            "title" => "Loops",
            "toggle" => "loop",
            "empty" => "No loop running.",
            "iterations" => "%{done}/%{max} iterations",
            "remaining" => "%{left} of %{total} left"
          },
          "skills" => {
            "title" => "Skills",
            "empty" => "No skills installed yet",
            "empty_in" => "in",
            "required" => " · required"
          },
          "tool_output" => {
            "label" => "Tool output",
            "verbose" => "Verbose — every tool call stays on screen",
            "compact" => "Compact — only the newest tool calls stay on screen"
          },
          "theme" => {
            "everforest" => "Everforest",
            "everforest_title" => "Everforest, dark green",
            "dark" => "Dark",
            "dark_title" => "Neutral dark",
            "light" => "Light"
          },
          # The speaker's name in front of a message, for a screen reader. The
          # bubble itself already says which side it is on.
          "message" => {
            "you" => "You: ",
            "rubot" => "Rubot: "
          },
          "working" => "Working…",
          "gate" => {
            "title" => "rubot · sign in",
            "brand" => "rubot",
            "no_token" => "This address carries no token. Enter the access token to go on.",
            "token" => "Token",
            "submit" => "Sign in",
            "token_mismatch" => "That token does not match."
          },
          "document" => {
            "title" => "rubot · %{title}"
          },
          "repin" => {
            "rebuilt" => "The prompt is rebuilt on the next message — memory, skills and AGENTS.md that changed come along.",
            "busy" => "A turn is still running. Send it again once that finishes: the prompt is built before the next message, not in the middle of an answer.",
            "none" => "The prompt is not pinned yet — the next message already builds it from the newest."
          },
          "compact" => {
            "now" => "Summarize the context now"
          },
          # The card the instagram tool asks for. Each button says what it is
          # doing while it does it, so both halves of the branch are named here.
          "instagram_connect" => {
            "prompt" => "Connect your Instagram Business/Creator account",
            "connect" => "Connect with Instagram",
            "connecting" => "Connecting…",
            "default" => "(default)",
            "disconnect" => "Disconnect",
            "disconnecting" => "Disconnecting…",
            "disconnect_confirm" => "Disconnect the Instagram account @%{account}?",
            "existing" => "(existing account)",
            "link" => "Link this account"
          },
          "lightbox" => {
            "label" => "Attachment preview",
            "download" => "Download",
            "close" => "Close",
            "close_label" => "Close the preview"
          },
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
              # The tooltip on each face: what the stack behind the name is.
              "font_titles" => {
                "serif" => "The default: Source Serif 4, with Charter and Georgia as fallbacks",
                "sans" => "A system face without serifs: Segoe UI, Roboto, or SF on an Apple device",
                "mono" => "Martian Mono, the fixed-width face the machine names are set in",
                "georgia" => "The device's own Georgia, with Times as a fallback",
                "palatino" => "The device's own Palatino, with the system serif as a fallback"
              },
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
        "ask" => {
          "confirm" => {
            "question" => "Kirim jawaban ini?",
            "send" => "Kirim",
            "send_description" => "Pakai jawaban ini dan lanjut",
            "restart" => "Ulangi",
            "restart_description" => "Tanyakan lagi dari awal"
          }
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
          "skill" => {
            "load" => "Memuat skill %{name}",
            "load_many" => "Memuat skill %{names}",
            "joiner" => " dan ",
            "separator" => ", ",
            "label" => "skill"
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
          "delegate_named" => "Meminta bantuan %{agent}",
          "ask" => "Bertanya: %{question}",
          "ask_plain" => "Bertanya sesuatu ke kamu"
        },
        "tui" => {
          "commands" => {
            "available" => "Perintah yang tersedia:",
            "keys" => "Tombol pintas:",
            "unknown" => "Perintah tidak dikenal: %{command}.",
            "unknown_hint" => "Ketik /help untuk melihat daftar perintah.",
            "stop_requested" => "Permintaan berhenti dikirim."
          },
          "session" => {
            "cleared" => "Sesi dibersihkan.",
            "switched" => "Sesi dialihkan ke: %{name}",
            "current" => "Sesi saat ini: %{id}",
            "model" => "Model: %{model}",
            "browse_hint" => "Ketik /resume untuk menelusuri sesi tersimpan.",
            "not_found" => "Sesi '%{query}' tidak ditemukan.",
            "see_hint" => "Ketik /resume untuk melihat daftar sesi tersimpan.",
            "none" => "Belum ada sesi tersimpan.",
            "none_hint" => "Percakapan disimpan begitu terjadi; /resume mengembalikannya nanti.",
            "other_dirs" => "%{count} percakapan dari direktori lain · /resume all",
            "list_title" => "Sesi tersimpan:",
            "messages_unit" => "pesan",
            "resume_hint" => "Lanjutkan satu dengan /resume <nomor> atau /resume <id>.",
            "other_dirs_more" => "%{count} lagi dari direktori lain · /resume all"
          },
          "prompt" => {
            "repinned" => "System prompt akan dibangun ulang pada pesan berikutnya.",
            "repinned_detail" => "Memori, skill, dan AGENTS.md yang berubah sejak sesi ini dimulai ikut terpakai.",
            "repinned_cost" => "Biayanya: permintaan berikutnya dibayar penuh — awalan prompt bergeser, jadi cache-nya hilang sekali.",
            "not_pinned" => "Prompt tidak dipin; pesan berikutnya tetap membangunnya dari berkas terbaru."
          },
          "info" => {
            "title" => "Info agen:"
          },
          "context" => {
            "live" => "live — permintaan yang sedang berjalan belum masuk hitungan ini"
          },
          "help" => {
            "cmd" => {
              "help" => "Tampilkan bantuan ini",
              "new" => "Bersihkan percakapan dan mulai sesi baru",
              "stop" => "Hentikan tugas yang sedang berjalan",
              "compact" => "Ringkas pesan lama untuk mengosongkan konteks",
              "repin" => "Bangun ulang system prompt pada pesan berikutnya (memori dan skill ikut terbaca, biayanya satu permintaan tanpa cache)",
              "clear" => "Bersihkan riwayat percakapan",
              "session" => "Tampilkan ID sesi saat ini",
              "session_name" => "Pindah ke sesi baru",
              "resume" => "Pilih sesi tersimpan untuk dilanjutkan",
              "resume_n_name" => "Lanjutkan sesi tersimpan",
              "search_kata" => "Cari di setiap pesan tersimpan, termasuk giliran yang sudah diringkas",
              "info" => "Tampilkan info agen (provider, model, tool)",
              "context" => "Tampilkan pemakaian konteks, cache hit rate, dan perkiraan biaya",
              "usage" => "Tampilkan pemakaian langganan OpenCode Go",
              "timing" => "Ke mana permintaan ke provider menghabiskan waktu (perlu RUBOT_TIMING=1 saat start)",
              "models" => "Daftar model yang didukung provider",
              "model" => "Tampilkan model yang sedang aktif",
              "use_model_name" => "Pindah model untuk sesi ini",
              "tools" => "Daftar tool yang tersedia",
              "soul" => "Tampilkan soul bot (SOUL.md)",
              "memory" => "Tampilkan memori permanen (MEMORY.md)",
              "agents" => "Tampilkan aturan agen (AGENTS.md)",
              "delegates" => "Daftar persona yang bisa menerima delegasi subagent",
              "cron" => "Daftar tugas cron terjadwal",
              "web_restart" => "Jalankan ulang kanal web (bin/rubot web)",
              "auto_on_off" => "Mode auto: jalankan aksi yang tidak merusak tanpa bertanya (diingat)",
              "stream_on_off" => "Alihkan keluaran streaming",
              "use_skill" => "Paksa satu skill untuk pesan berikutnya",
              "unuse" => "Hapus skill yang dipaksa",
              "quit" => "Keluar dari rubot"
            },
            "key" => {
              "enter" => "Kirim prompt, atau ambil /command yang disorot",
              "enter_running" => "Arahkan giliran yang sedang berjalan, bukan menunggunya",
              "shift_enter" => "Sisipkan baris baru (kotak ikut tumbuh)",
              "ctrl_g" => "Sunting prompt di $EDITOR, lalu ambil kembali",
              "tab" => "Lengkapi sebuah /command",
              "up_down" => "Pilih /command, pindah antar baris, atau telusuri riwayat",
              "ctrl_left_right" => "Geser kursor satu kata ke kiri atau kanan",
              "esc" => "Batalkan giliran yang berjalan, hapus pilihan, tutup daftar",
              "pgup_pgdn" => "Gulir percakapan",
              "ctrl_c" => "Keluar dari rubot"
            }
          },
          "model" => {
            "current" => "Model saat ini: %{model} (%{id})",
            "override" => "Override sesi — hilang saat /new.",
            "none" => "Tidak ada model yang tersedia.",
            "none_hint" => "Provider tidak memberi katalog model, dan config.yml tidak punya daftar model.",
            "no_match" => "Tidak ada model yang cocok dengan '%{filter}'.",
            "list_title" => "Model yang didukung %{provider}",
            "list_header" => "Model yang didukung %{provider}:",
            "provider_fallback" => "provider",
            "catalog_failed" => "Gagal membaca katalog model: %{message}",
            "usage" => "Pakai: /use-model <nama-model>",
            "switched" => "Berpindah ke model: %{model}",
            "switched_label" => "Berpindah ke model: %{model} (%{label})",
            "provider" => "Provider: %{provider}",
            "session_only" => "Berlaku untuk sesi ini saja (hilang saat /new).",
            "not_found" => "Model '%{name}' tidak ada di config.yml maupun katalog provider."
          },
          "tools" => {
            "title" => "Tool yang tersedia:"
          },
          "soul" => {
            "title" => "Soul (SOUL.md):",
            "none" => "Berkas soul (SOUL.md) tidak ditemukan di workspace."
          },
          "memory" => {
            "global" => "Memori — global: %{path}",
            "workspace" => "Memori — workspace ini: %{path}",
            "title" => "Memori (MEMORY.md):",
            "none" => "Memori tidak tersedia (workspace belum diatur)."
          },
          "agents" => {
            "title" => "Aturan agen (AGENTS.md):",
            "none" => "AGENTS.md tidak ditemukan di workspace."
          },
          "cron" => {
            "none" => "Tool cron tidak tersedia."
          },
          "stream" => {
            "state" => "Streaming %{state}.",
            "on" => "aktif",
            "off" => "nonaktif"
          },
          "skill" => {
            "cleared" => "Skill paksa dihapus.",
            "none" => "Tidak ada skill paksa yang aktif.",
            "usage" => "Pakai: /use <nama-skill>",
            "available" => "Skill yang tersedia: %{skills}",
            "empty" => "(tidak ada)",
            "off" => "Skill '%{name}' dimatikan untuk persona ini.",
            "off_hint" => "Nyalakan lagi dari daftar skill persona.",
            "forced" => "Skill '%{name}' akan dipakai untuk pesan berikutnya.",
            "not_found" => "Skill '%{name}' tidak ditemukan atau tidak aktif."
          },
          "web" => {
            "restarted" => "Server web dijalankan ulang.",
            "restart_failed" => "Server web gagal dijalankan ulang."
          },
          "delegates" => {
            "off" => "Delegasi mati. Set delegation.enabled: true di config.yml.",
            "none" => "Belum ada persona yang bisa menerima delegasi.",
            "title" => "Delegasi (%{count}):",
            "failed" => "Gagal membaca daftar delegasi: %{error}"
          },
          "auto" => {
            "usage" => "Pakai: /auto on|off (tanpa argumen membaliknya).",
            "on" => "Mode auto aktif — aksi yang tidak merusak berjalan tanpa bertanya.",
            "on_detail" => "Pola berbahaya (rm -rf /, mkfs, dd ke perangkat, …) tetap ditolak.",
            "off" => "Mode auto mati — setiap aksi berbahaya ditanya dulu."
          },
          "search" => {
            "title" => "Cari di arsip:",
            "hint" => "/search <kata> — setiap pesan tersimpan, termasuk giliran yang sudah diringkas",
            "no_archive" => "Arsip tidak terbuka, jadi tidak ada yang bisa dicari.",
            "no_archive_hint" => "Pencarian membaca arsip SQLite; tanpa itu percakapan berupa berkas dan /resume yang menampilkannya.",
            "nothing" => "Tidak ada yang cocok dengan %{query}.",
            "hits" => "%{count} hasil untuk %{query}:",
            "resume_hint" => "Lanjutkan satu dengan /resume <id>."
          }
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
          "chathead" => {
            "menu" => "Persona dan sesi",
            "rename" => "Ubah nama sesi",
            "rename_named" => "Ubah nama sesi: %{name}",
            "name_field" => "Nama sesi",
            "save_name" => "Simpan nama",
            "cancel" => "Batal"
          },
          "composer" => {
            "message" => "Pesan",
            "placeholder" => "Tulis pesan… Enter mengirim, Shift+Enter baris baru",
            "send" => "Kirim",
            "send_busy" => "Kirim sebagai arahan ke turn yang berjalan",
            "send_waiting" => "Menunggu compaction selesai",
            "unquote" => "Hapus kutipan",
            "stop" => "Batal",
            "stop_pending" => "Membatalkan…"
          },
          "emoji" => {
            "label" => "Emoji",
            "pick" => "Pilih emoji",
            "search" => "Cari emoji",
            "search_placeholder" => "Cari emoji…",
            "other" => "Emoji lain",
            "other_placeholder" => "Emoji lain…"
          },
          "confirm" => {
            "title" => "Konfirmasi: %{name}",
            "continue" => "Lanjutkan",
            "cancel" => "Batalkan"
          },
          "ask" => {
            "custom" => "Lainnya: tulis jawabanmu",
            "send" => "Kirim"
          },
          "search" => {
            "label" => "Cari percakapan",
            "placeholder" => "Cari di seluruh percakapan…",
            "hint" => "Cari di seluruh percakapan, termasuk yang sudah tidak ada di sidebar.",
            "close" => "Tutup (esc)",
            "open" => "Cari percakapan (⌘K)",
            "results" => "Hasil pencarian",
            "no_match" => "Tidak ada yang cocok dengan “%{query}”."
          },
          "personas" => {
            "rail_label" => "Persona",
            "new" => "Persona baru",
            "edit" => "Ubah persona",
            "slug" => "Slug",
            "slug_placeholder" => "kanyaah",
            "slug_hint" => "slug:",
            "name" => "Nama",
            "name_placeholder" => "Kanyaah",
            "default_model" => "Model default",
            "follow_default" => "Ikut default",
            "default_thinking" => "Thinking default",
            "system_prompt" => "System prompt",
            "prompt_placeholder" => "Kamu spesialis …",
            "prompt_keep" => "Kosongkan untuk memakai prompt bawaan",
            "create" => "Buat",
            "new_session" => "Sesi baru",
            "fact_persona" => "persona",
            "fact_model" => "model",
            "fact_session" => "sesi",
            "empty" => "%{name} punya SOUL, skills, dan memory sendiri. Apa pun yang dijalankannya lewat tool tampil di atas jawabannya. Sesi baru mulai dari percakapan kosong, dengan persona yang sama."
          },
          "sessions" => {
            "pinned" => "Di-pin",
            "recent" => "Terbaru",
            "pin_limit" => "Maksimal 10 sesi di-pin per persona",
            "empty_pinned" => "Belum ada sesi yang di-pin.",
            "empty_recent" => "Belum ada sesi.",
            "unread" => "belum dibaca",
            "unread_count" => "%{count} percakapan belum dibaca",
            "pin" => "Pin sesi",
            "unpin" => "Lepas pin",
            "delete" => "Hapus sesi",
            "delete_confirm" => "Hapus sesi ini? Seluruh percakapannya ikut hilang.",
            "untitled" => "Sesi baru",
            "more" => "Muat lebih banyak"
          },
          "attachments" => {
            "group" => "Lampiran dari Rubot",
            "play" => "Putar %{name}",
            "download" => "Unduh %{name}",
            "open" => "Buka %{name}",
            "file" => "BERKAS"
          },
          "turn" => {
            "empty_message" => "Pesan kosong.",
            "busy" => "Masih ada giliran yang berjalan. Tunggu sebentar atau tekan Stop.",
            "compacting" => "Sedang meringkas percakapan. Tunggu sebentar, lalu kirim lagi."
          },
          "markdown" => {
            "quote_paragraph" => "Kutip paragraf ini",
            "quote_list" => "Kutip daftar ini",
            "list_kind" => "Daftar · %{count} butir"
          },
          "usage" => {
            "row_cost" => "Total biaya sesi ini, akumulatif sejak permintaan pertama",
            "row_cache" => "Porsi prompt yang diambil dari cache pada permintaan terakhir — bukan rata-rata sesi",
            "row_context" => "Porsi context window model yang terpakai permintaan berikutnya",
            "sheet" => "Pemakaian",
            "prompt" => "Prompt",
            "repin" => "Bangun ulang",
            "repin_note" => "Memory, skill, dan AGENTS.md yang berubah di tengah sesi baru masuk setelah compaction — atau di sini, dengan ongkos satu request tanpa cache.",
            "facts" => {
              "model" => "model",
              "cost" => "biaya",
              "requests" => "permintaan",
              "messages" => "%{count} pesan",
              "tokens" => "token",
              "split" => "%{input} masuk · %{output} keluar",
              "reasoning" => "%{tokens} penalaran",
              "reread" => "dibaca ulang",
              "reread_value" => "%{tokens} token",
              "reread_title" => "Bagian dari permintaan terakhir yang dibayar dengan harga penuh: itulah yang dimakan pergeseran prefix.",
              "cache" => "cache",
              "saved" => "dihemat",
              "saved_title" => "Selisih harga input penuh dengan harga baca cache untuk token yang terbaca dari cache. Bukan bagian dari biaya — ini uang yang tidak keluar.",
              "cache_history" => "riwayat cache",
              "cache_history_title" => "Porsi cache tiap permintaan, terlama dulu. Deretan 0% berarti prefix prompt berubah terus; satu 0% setelah compaction itu wajar.",
              "context" => "konteks",
              "unknown" => "belum diketahui",
              "cost_in" => "masuk %{value}",
              "cost_cache_read" => "cache baca %{value}",
              "cost_cache_write" => "cache tulis %{value}",
              "cost_out" => "keluar %{value}",
              "cache_from" => "%{tokens} token dari cache",
              "cache_shares" => "%{last}% permintaan terakhir · %{session}% rata-rata sesi · %{tokens} token total"
            }
          },
          "quota" => {
            "label" => "Kuota",
            "checking" => "Memeriksa kuota…",
            "used" => "%{percent}% terpakai",
            "reset_in" => "reset dalam %{when}",
            "unavailable" => "Provider ini tidak punya kuota langganan; biayanya dihitung per token.",
            "error" => "Kuota tidak bisa diperiksa — %{error}.",
            "check_failed" => "Kuota tidak bisa diperiksa sekarang.",
            "meters" => {
              "rolling" => "5 jam",
              "weekly" => "mingguan",
              "monthly" => "bulanan"
            }
          },
          "session_settings" => {
            "trigger" => "Model dan level thinking sesi ini: %{model}, %{thinking}",
            "dialog" => "Model dan level thinking",
            "search" => "Cari model",
            "search_placeholder" => "Cari model…",
            "models" => "Model",
            "no_match" => "Tidak ada model yang cocok.",
            "thinking" => "thinking",
            "choose_model" => "pilih model",
            "count" => "%{count} model"
          },
          "subagents" => {
            "title" => "Subagent",
            "toggle" => "subagent",
            "empty" => "Belum ada subagent di percakapan ini.",
            "running" => "%{count} subagent berjalan",
            "running_one" => "1 subagent berjalan",
            "failed" => "subagent gagal",
            "done" => "subagent selesai"
          },
          "loops" => {
            "title" => "Loop",
            "toggle" => "loop",
            "empty" => "Tidak ada loop berjalan.",
            "iterations" => "%{done}/%{max} iterasi",
            "remaining" => "sisa %{left} dari %{total}"
          },
          "skills" => {
            "title" => "Skill",
            "empty" => "Belum ada skill terpasang",
            "empty_in" => "di",
            "required" => " · wajib"
          },
          "tool_output" => {
            "label" => "Tampilan tool",
            "verbose" => "Verbose — semua panggilan tool tetap tampil",
            "compact" => "Compact — hanya panggilan tool terbaru yang tampil"
          },
          "theme" => {
            "everforest" => "Everforest",
            "everforest_title" => "Everforest, hijau gelap",
            "dark" => "Gelap",
            "dark_title" => "Gelap netral",
            "light" => "Terang"
          },
          "message" => {
            "you" => "Kamu: ",
            "rubot" => "Rubot: "
          },
          "working" => "Bekerja…",
          "gate" => {
            "title" => "rubot · masuk",
            "brand" => "rubot",
            "no_token" => "Alamat ini tidak membawa token. Masukkan token akses untuk melanjutkan.",
            "token" => "Token",
            "submit" => "Masuk",
            "token_mismatch" => "Token tidak cocok."
          },
          "document" => {
            "title" => "rubot · %{title}"
          },
          "repin" => {
            "rebuilt" => "Prompt akan dibangun ulang pada pesan berikutnya — memory, skill, dan AGENTS.md yang berubah ikut masuk.",
            "busy" => "Turn masih berjalan. Kirim ulang setelah selesai: prompt dibangun sebelum pesan berikutnya, bukan di tengah jawaban.",
            "none" => "Prompt belum di-pin — pesan berikutnya memang sudah membangunnya dari yang terbaru."
          },
          "compact" => {
            "now" => "Ringkas konteks sekarang"
          },
          "instagram_connect" => {
            "prompt" => "Hubungkan akun Instagram Business/Creator kamu",
            "connect" => "Connect dengan Instagram",
            "connecting" => "Menghubungkan…",
            "default" => "(default)",
            "disconnect" => "Putuskan",
            "disconnecting" => "Memutus…",
            "disconnect_confirm" => "Putuskan akun Instagram @%{account}?",
            "existing" => "(akun existing)",
            "link" => "Link akun ini"
          },
          "lightbox" => {
            "label" => "Pratinjau lampiran",
            "download" => "Unduh",
            "close" => "Tutup",
            "close_label" => "Tutup pratinjau"
          },
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
              "font_titles" => {
                "serif" => "Bawaan: Source Serif 4, dengan Charter dan Georgia sebagai cadangan",
                "sans" => "Huruf sistem tanpa kait: Segoe UI, Roboto, atau SF di perangkat Apple",
                "mono" => "Martian Mono, huruf berjarak tetap yang dipakai nama mesin",
                "georgia" => "Georgia milik perangkat, dengan Times sebagai cadangan",
                "palatino" => "Palatino milik perangkat, dengan serif sistem sebagai cadangan"
              },
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
