# a2ui.el

Let AI agents draw native, interactive UI in Emacs: forms, tables, diffs and pickers, rendered in a buffer and bound to live data.

[![CI](https://github.com/chazu/a2ui.el/actions/workflows/test.yml/badge.svg)](https://github.com/chazu/a2ui.el/actions/workflows/test.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

[A2UI](https://a2ui.org) is a protocol in which an agent describes UI as JSON (components, a data model, actions) instead of writing code. a2ui.el renders those surfaces with [vui.el](https://github.com/d12frosted/vui.el). You fill them in with normal editing keys, and the agent gets your answers when you press a button. Nothing the agent sends is ever evaluated as code.

```
Review: tidy a2ui-vui docstrings
Rewords one docstring.  No behaviour change.
▾ Files (2)
  File        + -
  a2ui-vui.el 1 1
  DESIGN.md   4 0
a2ui-vui.el
--- a/a2ui-vui.el
+++ b/a2ui-vui.el
@@ -44,3 +44,3 @@
 (defcustom a2ui-vui-width 60
-  "Width of rules."
+  "Width in characters of rules drawn by Card and Divider."
   :type 'natnum
[Accept]  [Reject]
▸ Context
Reviewer: [Select...]
[Merge]
```

*The `examples/code-review.jsonl` surface. Section, Table, Diff, Picker and OrgText are from the Emacs catalog. Faces come from your theme and `diff-mode`.*

## Features

- **The A2UI v0.9 basic catalog**: Text with Markdown, Column, Row, List, Card, Divider, Icon, Button, TextField (including multi-line, edited in its own buffer), CheckBox, ChoicePicker, Slider, DateTimeInput (using `org-read-date`), Tabs and Modal (its content opens in a popup window). Images show inline in graphical frames, after asking before anything is fetched; Video and AudioPlayer appear as links.
- **An Emacs catalog**: the basic components plus Section (folds), Table (row selection and row actions), Diff (fontified by `diff-mode`, with Accept/Reject), Code (fontified by the language's major mode), Picker (`completing-read`), FileRef and OrgText.
- **Live binding**: inputs write to the data model as you type, and checks run as you go. A field's errors show once you've touched it, or after a blocked submit.
- **Works with the agents you already use**: gptel (native tools), agent-shell (Claude Code, Codex and other ACP agents), Claude Code or Codex in a terminal (through an MCP server inside Emacs), and any [AG-UI](https://docs.ag-ui.com) agent. See [Connecting an agent](#connecting-an-agent).
- **Feedback for the model**: invalid surfaces come back to it as compact errors so it can fix them. AG-UI interrupts become Approve/Reject surfaces.
- **Token-efficient prompting**: models get a compact catalog digest of about 950 tokens, only when they ask for it, instead of a 5,000-token JSON Schema. `update_a2ui` changes part of a surface without resending it.
- **No agent required**: `a2ui-replay-file` renders a file of A2UI messages.

## Requirements

- Emacs 29.1 or later
- [vui.el](https://github.com/d12frosted/vui.el) from MELPA. The older `1.4.0` on MELPA-stable is not enough.
- `curl` 7.76 or later, for talking to AG-UI agents
- For a given agent: [gptel](https://github.com/karthink/gptel), [agent-shell](https://github.com/xenodium/agent-shell), Claude Code or Codex, as below

## Installation

### straight.el + use-package

```elisp
(use-package a2ui
  :straight (a2ui :type git :host github :repo "chazu/a2ui.el"
                  :files (:defaults "catalogs")))
```

### use-package from MELPA (once accepted)

```elisp
(use-package a2ui :ensure t)
```

### Manually

Clone the repository, install `vui` from MELPA, then:

```elisp
(add-to-list 'load-path "/path/to/a2ui.el")
(require 'a2ui)
```

The `catalogs/` directory must sit next to the `.el` files.

## Quick start

Render a surface without any agent:

```
M-x a2ui-replay-file RET examples/code-review.jsonl RET
M-x a2ui-show-log
```

Press `[Merge]` without picking a reviewer and the button refuses. Pick one, press it again, and the action appears in `*a2ui-log*`.

## Connecting an agent

Every host gets the same four tools:

| Tool | What it does |
|---|---|
| `render_a2ui` | Show or replace a surface (`surfaceId`, flat `components`, `data`) |
| `update_a2ui` | Change some components or data paths of a surface |
| `a2ui_catalog` | The compact component list, or the full schema of named components |
| `a2ui_await_action` | Wait for the user's next button press |

Surfaces open in their own buffers (see `display-buffer-alist` under [Configuration](#configuration)). A button press reaches the model in one of two ways:
- as the result of a pending `a2ui_await_action`, when the model is waiting;
- otherwise as your next message, in hosts that take messages (gptel, agent-shell).

You don't need to name components in your request. "Show me something to review this change with" is enough: the model reads the catalog and picks.

### gptel

```elisp
(use-package a2ui
  :after gptel
  :config
  (require 'a2ui-gptel)
  (a2ui-gptel-enable))     ; adds the A2UI tools to gptel-tools
```

Ask for UI in any gptel chat buffer, e.g. *"Show me a form to collect the deploy target and replica count."* When you press a button, the press is typed into the chat as `User performed action "…" … Context: {…}` and sent, so the model answers in the conversation. Set `a2ui-gptel-send-actions` to nil to have the model wait in `a2ui_await_action` instead. Each chat buffer has its own surfaces.

You can turn the tools on or off per buffer from gptel's tool menu (category `a2ui`). Small local models often skip `a2ui_catalog` and guess component shapes. Setting `a2ui-tools-catalog-in-description` to t puts the digest in the tool description, at about 950 tokens per request.

Use a model that calls tools reliably. These were checked live with `examples/agents/drive-gptel.el`, through OpenRouter:
- Claude Haiku 5.5 got it right on the first try, both waiting in `a2ui_await_action` and taking the press as a chat message.
- Qwen3-Coder fixed its surfaces from the validation errors, then finished.
- GPT-4o-mini finished one run in two.
- A 7B Ollama model ran the tools but often wrote its calls as text.

### agent-shell (Claude Code, Codex, …)

```elisp
(use-package a2ui
  :after agent-shell
  :config
  (require 'a2ui-agent-shell)
  (a2ui-agent-shell-setup))  ; before starting shells
```

`a2ui-agent-shell-setup` adds an a2ui MCP server to `agent-shell-mcp-servers`. Every shell started afterwards gets its own endpoint, so its surfaces and button presses stay with it. Ask for UI as usual. When you press a button, the press is submitted to that shell as your next prompt, or queued if the agent is busy.

The setup also installs a permission responder that approves a2ui's own tools, which only draw UI and report your clicks. Every other permission request is still asked as usual. Set `a2ui-agent-shell-auto-approve` to nil to be asked each time. This was verified with Claude Code through `claude-agent-acp`. Other ACP agents that accept HTTP MCP servers get the same tools.

### Claude Code in a terminal

Start the endpoint in Emacs, then register it with Claude Code once:

```
M-x a2ui-mcp-start          ; shows and copies the URL
claude mcp add --transport http a2ui http://127.0.0.1:PORT/mcp/TOKEN
```

To skip permission prompts for the a2ui tools, add `"mcp__a2ui"` to `permissions.allow` in `~/.claude/settings.json`.

A terminal agent can't receive messages from Emacs, so it learns of button presses through `a2ui_await_action`. Ask it to wait for you (*"…then wait for my decision"*), or press the button and then tell it to continue. Verified with Claude Code 2.1 (`claude -p`, Sonnet): it drew the surface, waited, and reported the choice.

The port and token change with every Emacs session unless you pin them:

```elisp
(setq a2ui-mcp-port 7841
      a2ui-mcp-token "3f9c0a7e5d1b42c8a6e0")  ; any private hex string
```

### Codex in a terminal

Use the same endpoint:

```
M-x a2ui-mcp-start
codex mcp add a2ui --url http://127.0.0.1:PORT/mcp/TOKEN
```

Then, in `~/.codex/config.toml`, let Codex use the tools without asking and give `a2ui_await_action` time to wait:

```toml
[mcp_servers.a2ui]
url = "http://127.0.0.1:PORT/mcp/TOKEN"
default_tools_approval_mode = "approve"
tool_timeout_sec = 300
```

Without `default_tools_approval_mode`, `codex exec` refuses MCP tool calls, since it never prompts. Verified with Codex 0.163 (`codex exec`): it called `a2ui_catalog`, rendered the review, waited and reported the choice.

### AG-UI agents

```elisp
(setq a2ui-agui-agents
      '(("local" :url "http://127.0.0.1:8770/")
        ("work"  :url "https://agents.example.com/run"
                 :headers (("Authorization" . a2ui-agui-auth-from-authinfo)))))
```

```
M-x a2ui-agui-send RET deploy the billing service RET
```

The client declares `render_a2ui` to the agent, sends the catalog digest as context, and handles the AG-UI A2UI middleware's activity events. Behind that middleware, set `a2ui-agui-action-encoding` to `forwarded-props`.

`examples/agents/` has test agents, each run with `uv run`:
- `deploy_agent.py` is scripted and needs no API key.
- `llm_agent.py` is backed by OpenAI.
- `claude_agent.py` uses your Claude Code login through `claude -p`.

The `drive-*.el` files next to them play the user in batch Emacs against each host:
- `drive-gptel.el` for gptel
- `drive-agent-shell.el` for agent-shell
- `drive-mcp.el` for Claude Code or Codex in a terminal
- `drive-deploy.el` and `drive-catalog.el` for AG-UI agents

## Configuration

```elisp
(use-package a2ui
  :straight (a2ui :type git :host github :repo "chazu/a2ui.el"
                  :files (:defaults "catalogs"))
  :custom
  (a2ui-vui-width 72)
  (a2ui-confirm-open-url t)
  (a2ui-agui-catalog-detail 'digest)
  :config
  (setq a2ui-agui-agents '(("local" :url "http://127.0.0.1:8770/")))
  ;; Show surfaces in a side window.
  (add-to-list 'display-buffer-alist
               '("\\`\\*a2ui: " (display-buffer-in-side-window)
                 (side . right) (window-width . 0.4))))
```

## Usage

| Command | What it does |
|---|---|
| `a2ui-gptel-enable` | Add the A2UI tools to `gptel-tools` |
| `a2ui-agent-shell-setup` | Give agent-shell agents the A2UI tools |
| `a2ui-mcp-start` / `a2ui-mcp-stop` | Run the MCP endpoint for Claude Code or Codex in a terminal |
| `a2ui-agui-connect` | Start a thread with an agent from `a2ui-agui-agents`, or with a URL |
| `a2ui-agui-send` | Send a message to the current agent; surfaces appear as it answers |
| `a2ui-agui-abort` | Stop the running request |
| `a2ui-list-surfaces` | Every live surface; `RET` shows one, `d` deletes it |
| `a2ui-replay-file` | Feed a `.jsonl` file of A2UI messages into a local session |
| `a2ui-show-log` | Every A2UI message in and out, as pretty JSON |
| `a2ui-agui-show-log` | Raw AG-UI traffic, one event per line |

In a surface buffer:

| Key | Action |
|---|---|
| `TAB` / `S-TAB` | Move between controls |
| `RET` | Activate a button, checkbox, picker or link; fold a Section; pick a tab |
| `<left>` / `<right>` | Previous or next tab (point on a tab title) |
| `-` / `+` | Step a Slider (point on its value) |
| `g` | Re-render |
| `q` | Bury the buffer |
| `C-c C-k` | Delete the surface; a model waiting in `a2ui_await_action` is told it was closed |

In a long-text edit buffer, `C-c C-c` saves and `C-c C-k` cancels. A Modal's popup closes with `C-c C-k` (or `C-c C-c`); edits in it go to the surface's data like any other.

## Customization

| Option | Default | Purpose |
|---|---|---|
| `a2ui-tools-catalog-in-description` | `nil` | Put the catalog digest in `render_a2ui`'s description instead of on demand |
| `a2ui-tools-await-timeout` | `120` | Seconds `a2ui_await_action` waits by default |
| `a2ui-gptel-send-actions` | `t` | Send button presses to the gptel chat as messages |
| `a2ui-agent-shell-auto-approve` | `t` | Approve a2ui's own tools in agent-shell |
| `a2ui-mcp-port`, `a2ui-mcp-token` | `0`, `nil` | Pin the `a2ui-mcp-start` endpoint across sessions |
| `a2ui-agui-agents` | `nil` | Agents as `(NAME :url URL :headers ALIST [:action-encoding ...])` |
| `a2ui-agui-action-encoding` | `messages` | `messages` writes actions into the history; `forwarded-props` suits agents behind the AG-UI A2UI middleware |
| `a2ui-agui-catalog-detail` | `digest` | Catalog info per run: `digest`, `schema` or `nil` (ids only) |
| `a2ui-agui-default-catalog-id` | `nil` | Catalog for `render_a2ui` calls without one; `nil` uses the most capable catalog |
| `a2ui-agui-render-retries` | `2` | Times in a row a failed render is sent straight back |
| `a2ui-agui-curl-program` | `"curl"` | The curl executable |
| `a2ui-vui-width` | `60` | Width of rules and wrapped rows |
| `a2ui-vui-field-width` | `30` | Width of text fields |
| `a2ui-vui-auto-show` | `t` | Display new surfaces at once |
| `a2ui-vui-inline-images` | `ask` | Images: `ask` before fetching, `t` fetch at once, `nil` links only |
| `a2ui-vui-image-hosts` | `nil` | Hosts whose images are fetched without asking |
| `a2ui-vui-image-max-bytes` | 5 MB | Largest image fetched |
| `a2ui-vui-modal-display-action` | below, fitted | How a Modal's popup is displayed |
| `a2ui-trust-agent-display-name` | `nil` | Show the surface's own `agentDisplayName` instead of the configured agent name |
| `a2ui-confirm-open-url` | `t` | Ask before opening a URL; only http(s) is ever opened |
| `a2ui-time-zone` | `nil` | Zone for `formatDate`; `nil` means local time |
| `a2ui-emacs-language-modes` | (alist) | Major modes for Code components |
| `a2ui-log-messages`, `a2ui-agui-log-events` | `t` | Whether to keep the logs |

## For package authors

To offer the A2UI tools in another host, make an `a2ui-tools-host` and pass tool calls to `a2ui-tools-call`; `a2ui-gptel.el` is a short example. The protocol core and the renderer don't depend on any host, so any transport can feed them:

```elisp
(let ((session (a2ui-session-create
                :name "my-agent"
                :send-action-fn (lambda (message _metadata)
                                  (my-send-to-agent (a2ui-json-encode message))))))
  (a2ui-vui-attach session)               ; show surfaces as they appear
  (a2ui-apply-message session json-text)  ; feed messages from anywhere
  (a2ui-catalog-digest (a2ui-catalog 'emacs)))  ; for the model's prompt
```

New components and functions are registered per catalog:

```elisp
(a2ui-define-component emacs "Magit" (c surface scope) ...)
(a2ui-define-function emacs "projectRoot" () (project-root (project-current)))
```

The files:

| File | Role |
|---|---|
| `a2ui-core.el` | A2UI as pure data: sessions, surfaces, JSON Pointer, functions, validation |
| `a2ui-vui.el` | The vui.el renderer and the basic catalog's components |
| `a2ui-emacs.el` | The Emacs catalog |
| `a2ui-tools.el` | The A2UI tools, defined once for every host |
| `a2ui-gptel.el` | gptel adapter |
| `a2ui-mcp.el` | MCP server (HTTP) inside Emacs |
| `a2ui-agent-shell.el` | agent-shell adapter |
| `a2ui-agui.el` | The AG-UI client |
| `a2ui.el` | User commands and logs |

`DESIGN.md` explains the architecture and the decisions behind it.

## Development

```sh
eldev test                         # ERT: units, snapshots, interaction, AG-UI streams
A2UI_UPDATE_GOLDEN=1 eldev test    # rewrite render snapshots after a deliberate change
eldev lint && eldev lint doc       # package-lint and checkdoc
eldev compile --warnings-as-errors
python3 scripts/build-emacs-catalog.py   # regenerate catalogs/emacs/catalog.json
```

`benchmarks/a2ui-bench.el` times rendering and typing into large surfaces. The `examples/agents/drive-*.el` files play the user against live agents in batch Emacs. `drive-gptel.el` takes `A2UI_GPTEL_BACKEND` (`ollama` or `openrouter`), `A2UI_GPTEL_MODEL` and `A2UI_GPTEL_CHAT`; `drive-agent-shell.el` takes `A2UI_PROMPT`.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE). The A2UI basic catalog and spec examples under `catalogs/basic/` and `test/fixtures/examples/` are Apache-2.0, from the [A2UI project](https://github.com/google/A2UI).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
