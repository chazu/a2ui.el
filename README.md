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

- **The A2UI v0.9 basic catalog**: Text with Markdown, Column, Row, List, Card, Divider, Icon, Button, TextField (including multi-line, edited in its own buffer), CheckBox, ChoicePicker, Slider and DateTimeInput (using `org-read-date`). Image, Video and AudioPlayer appear as links. Tabs and Modal are not supported yet.
- **An Emacs catalog**: the basic components plus Section (folds), Table (row selection and row actions), Diff (fontified by `diff-mode`, with Accept/Reject), Code (fontified by the language's major mode), Picker (`completing-read`), FileRef and OrgText.
- **Live binding**: inputs write to the data model as you type, and checks run as you go. A field's errors show once you've touched it, or after a blocked submit.
- **An [AG-UI](https://docs.ag-ui.com) client**: works with any AG-UI agent, including ones behind the AG-UI A2UI middleware. Interrupts become Approve/Reject surfaces, and invalid renders go back to the agent to fix.
- **Token-efficient prompting**: agents get a compact catalog digest of about 900 tokens instead of a 5,000-token JSON Schema.
- **No agent required**: `a2ui-replay-file` renders a file of A2UI messages.

## Requirements

- Emacs 29.1 or later
- [vui.el](https://github.com/d12frosted/vui.el) from MELPA. The older `1.4.0` on MELPA-stable is not enough.
- `curl` 7.76 or later, for talking to AG-UI agents

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

Talk to an AG-UI agent:

```elisp
(setq a2ui-agui-agents
      '(("local" :url "http://127.0.0.1:8770/")
        ("work"  :url "https://agents.example.com/run"
                 :headers (("Authorization" . a2ui-agui-auth-from-authinfo)))))
```

```
M-x a2ui-agui-send RET deploy the billing service RET
```

`examples/agents/` has two test agents. `deploy_agent.py` is scripted and needs no API key. `llm_agent.py` is backed by OpenAI. Run either with `uv run`.

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
| `a2ui-agui-connect` | Start a thread with an agent from `a2ui-agui-agents`, or with a URL |
| `a2ui-agui-send` | Send a message to the current agent; surfaces appear as it answers |
| `a2ui-agui-abort` | Stop the running request |
| `a2ui-replay-file` | Feed a `.jsonl` file of A2UI messages into a local session |
| `a2ui-show-log` | Every A2UI message in and out, as pretty JSON |
| `a2ui-agui-show-log` | Raw AG-UI traffic, one event per line |

In a surface buffer:

| Key | Action |
|---|---|
| `TAB` / `S-TAB` | Move between controls |
| `RET` | Activate a button, checkbox, picker or link; fold a Section |
| `-` / `+` | Step a Slider (point on its value) |
| `g` | Re-render |
| `q` | Bury the buffer |
| `C-c C-k` | Delete the surface |

In a long-text edit buffer, `C-c C-c` saves and `C-c C-k` cancels.

## Customization

| Option | Default | Purpose |
|---|---|---|
| `a2ui-agui-agents` | `nil` | Agents as `(NAME :url URL :headers ALIST [:action-encoding ...])` |
| `a2ui-agui-action-encoding` | `messages` | `messages` writes actions into the history; `forwarded-props` suits agents behind the AG-UI A2UI middleware |
| `a2ui-agui-catalog-detail` | `digest` | Catalog info per run: `digest`, `schema` or `nil` (ids only) |
| `a2ui-agui-default-catalog-id` | `nil` | Catalog for `render_a2ui` calls without one; `nil` uses the most capable catalog |
| `a2ui-agui-render-retries` | `2` | Times in a row a failed render is sent straight back |
| `a2ui-agui-curl-program` | `"curl"` | The curl executable |
| `a2ui-vui-width` | `60` | Width of rules and wrapped rows |
| `a2ui-vui-field-width` | `30` | Width of text fields |
| `a2ui-vui-auto-show` | `t` | Display new surfaces at once |
| `a2ui-trust-agent-display-name` | `nil` | Show the surface's own `agentDisplayName` instead of the configured agent name |
| `a2ui-confirm-open-url` | `t` | Ask before opening a URL; only http(s) is ever opened |
| `a2ui-time-zone` | `nil` | Zone for `formatDate`; `nil` means local time |
| `a2ui-emacs-language-modes` | (alist) | Major modes for Code components |
| `a2ui-log-messages`, `a2ui-agui-log-events` | `t` | Whether to keep the logs |

## For package authors

The protocol core and the renderer don't depend on AG-UI, so any transport can feed them:

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

`benchmarks/a2ui-bench.el` times rendering and typing into large surfaces. `examples/agents/drive-deploy.el` plays the deploy example against a live agent in batch Emacs.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE). The A2UI basic catalog and spec examples under `catalogs/basic/` and `test/fixtures/examples/` are Apache-2.0, from the [A2UI project](https://github.com/google/A2UI).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
