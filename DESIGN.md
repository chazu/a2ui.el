# a2ui.el — Generative UI for Emacs: Design

Oct 19, 2026 · @Chaz Straney

## Summary

**a2ui.el** lets any agent that speaks A2UI draw interactive, native Emacs UI: forms, lists, cards and pickers rendered in a buffer and bound to live data. It is three layers with one job each:

- **A2UI core** (`a2ui-core.el`): the protocol as pure data. Surfaces, components, data models, functions, validation. No UI, no network.
- **vui renderer** (`a2ui-vui.el`): turns a surface into a vui.el component tree and routes user input back into the data model and out as actions.
- **AG-UI transport** (`a2ui-agui.el`): an SSE client for AG-UI agents that pulls A2UI payloads out of the run stream and sends actions back as the next run.

v0.1 is "simple but useful" when one AG-UI agent can show a form in Emacs, the user fills it in with normal editing keys, presses a button, and the agent receives the values. Everything beyond that loop is later.

## Goals and non-goals

The library renders agent-declared UI safely and natively; it does not run agents, and it never evaluates agent-supplied code.

**Goals**

- Render A2UI v0.9.x surfaces in Emacs buffers with progressive updates as messages stream in.
- Two-way binding: inputs write the local data model immediately; actions carry resolved values to the agent.
- Keyboard-first: every control reachable with TAB / RET and normal editing keys; theme-aware faces.
- A transport-neutral core, so MCP, ACP or a local gptel tool can feed the same renderer later.
- One working AG-UI transport out of the box.
- An Emacs-native catalog (org tables, diffs, collapsible sections, completing-read pickers) alongside a subset of the basic catalog.

**Non-goals for v0.1**

- Agent-writes-elisp UI. That is a separate, unsandboxed mode and stays out of this library.
- Pixel-faithful rendering of the basic catalog. Image, Video and AudioPlayer degrade to links.
- Hosting MCP Apps (HTML in iframes); possible later via xwidget-webkit, not designed here.
- Being an agent chat client. Hosts like agent-shell or gptel own the transcript; this library owns surfaces.

## Architecture

Three Emacs packages in one repo, layered so that each depends only on the one below it: the transport feeds the core, the core feeds the renderer, and no layer reaches past its neighbour.

&#91;embedded content: a2ui.el architecture · 3 layers, pluggable transports\]

Messages flow down from agent to buffer; actions flow back up the same path. Other transports plug in beside AG-UI and feed the same core.

| File | Depends on | Size target |
| --- | --- | --- |
| `a2ui-core.el` | Emacs 29.1 (native JSON) | \~800 lines |
| `a2ui-vui.el` | core, vui.el | \~600 lines + catalog files |
| `a2ui-agui.el` | core, curl | \~500 lines |
| `a2ui.el` | all three; user commands and defaults | \~150 lines |

## Core protocol layer (a2ui-core.el)

The core is a pure state machine: `(a2ui-apply-message SESSION MSG)` mutates surface state and returns the ids of surfaces that changed. It knows nothing about buffers or HTTP, so it is fully testable in batch Emacs.

**Data structures**

```elisp
(cl-defstruct a2ui-session
  surfaces          ; hash: surfaceId -> a2ui-surface
  catalogs          ; hash: catalogId -> a2ui-catalog
  send-action-fn    ; (lambda (action metadata)) supplied by the transport
  on-change-fn)     ; (lambda (surface-id)) supplied by the renderer

(cl-defstruct a2ui-surface
  id catalog-id theme send-data-model
  components        ; hash: componentId -> alist (parsed JSON)
  data              ; the data model, parsed JSON (hash tables / vectors)
  errors)           ; validation errors not yet reported
```

JSON is parsed with `json-parse-string` using `:object-type 'hash-table` and `:array-type 'array`, so JSON Pointer maps cleanly onto `gethash` and `aref`.

**Message application**

| Message | Core behaviour |
| --- | --- |
| `createSurface` | Error if the id exists; else create with catalog, theme, `sendDataModel`. Unknown catalog → report `error` to agent. |
| `updateComponents` | Upsert each component by `id`. Missing `root` is legal; renderer waits. |
| `updateDataModel` | Upsert at `path` (default `/`); omitted `value` removes the key, or sets an array slot to nil. |
| `deleteSurface` | Remove surface; notify renderer to unmount. |

Each message is checked for a `version` field and dispatched through a per-version table, so v1.0 can be added without touching v0.9 code.

**JSON Pointer**

- `a2ui-pointer-get DATA PATH SCOPE` and `a2ui-pointer-set`, RFC 6901 escaping (`~0`, `~1`).
- Relative paths (no leading `/`) resolve against SCOPE, the item path of the current list template, for example `/employees/2`.
- Set creates intermediate objects; a non-numeric segment on an array is an error.
- Missing data resolves to nil and renders as empty, which is what makes progressive rendering work.

**Dynamic values and functions**

`a2ui-resolve VALUE SCOPE` handles the three `Dynamic*` forms: a literal, `{path}`, or a `FunctionCall` (`{call, args}`), recursively. Functions live in a registry keyed by catalog:

```elisp
(a2ui-define-function basic required (value)
  (not (or (null value) (equal value "") (equal value []))))
```

v0.1 implements `required`, `regex`, `length`, `numeric`, `email`, `and`, `or`, `not`, `formatString`, `formatNumber`, `formatDate` and `openUrl` (via `browse-url`). `formatString` gets a small parser for `${...}` with nesting and `\${` escapes.

**Checks and validation**

- `checks` on an input yield a list of failing messages; on a Button any failure disables it.
- Incoming components are checked against the catalog (known type, `ComponentId` references) before they are stored. Failures are sent back as `{"error": {"code": "VALIDATION_FAILED", "surfaceId", "path", "message"}}` so the LLM can self-correct.

**Outbound messages**

`a2ui-dispatch-action SURFACE COMPONENT` resolves the action's `context` against the current data model and builds `{name, surfaceId, sourceComponentId, timestamp, context}`. If the surface has `sendDataModel`, the full data model goes in metadata. It then calls the session's `send-action-fn`; the core never knows which transport is behind it.

## Renderer layer (a2ui-vui.el)

Each surface is one vui component that re-renders from `root` whenever the core reports a change; vui's reconciliation decides what actually moves in the buffer. The renderer owns no protocol state; it reads the core's surface and writes back only through core functions.

**Mounting**

```elisp
(vui-defcomponent a2ui-surface-view (session surface-id)
  :state ((tick 0))   ; bumped by the session's on-change-fn
  :render
  (let ((s (a2ui-session-surface session surface-id)))
    (if-let ((root (a2ui-surface-component s "root")))
        (a2ui-vui-render s root nil)       ; nil = root scope
      (vui-text "Waiting for agent…" :face 'shadow))))
```

`a2ui-show-surface` mounts this with `vui-mount` into a buffer named `*a2ui: <surfaceId>*`. Transport callbacks arrive on process filters, so the change hook re-enters vui through `vui-with-async-context`.

**Component dispatch**

`a2ui-vui-render SURFACE COMPONENT SCOPE` looks up the component's type in the surface's catalog and calls its render function with the component alist, the surface and the scope. Unknown types and dangling child ids render a dim `[unknown: Type]` placeholder and queue a validation error, rather than breaking the whole surface.

Render functions are registered with a macro so catalogs stay declarative:

```elisp
(a2ui-define-component basic "TextField" (c surface scope)
  (let ((path (a2ui-binding-path c 'value scope)))
    (vui-field :value (a2ui-get surface path)
               :on-change (lambda (v) (a2ui-set surface path v))
               :label (a2ui-resolve-prop c 'label surface scope))))
```

**Children and templates**

- A static `children` array renders each id in order.
- A template `{path, componentId}` maps over the array at `path` and renders the template once per item, with scope set to `path/N`, so relative bindings inside it resolve per row.
- vui keys each templated child by `componentId` plus index, so reordering and appending rows don't redraw the whole list.

**Two-way binding**

Input widgets call `a2ui-set` on change, which writes the core's data model and fires the change hook; every component bound to that path re-renders. Nothing goes over the network on a keystroke. Checks run on render, and failing messages show under the field in an error face.

**Actions**

A Button with `action.event` calls `a2ui-dispatch-action`. One with `action.functionCall` runs the registered local function, for example `openUrl`. A Button whose checks fail renders with an inactive face and ignores RET, with its failing message shown as `help-echo` and in the echo area on attempt.

**Progressive rendering**

No root yet means a placeholder. Missing children render as placeholders. Unresolved data renders empty. The surface fills in as `updateComponents` and `updateDataModel` arrive, which is what A2UI's adjacency list is designed for.

**Faces and theme**

Components use a small set of `a2ui-*` faces inheriting from standard ones (`button`, `widget-field`, `error`, `shadow`, `bold`). `theme.primaryColor` is ignored by default (Emacs themes win); `theme.agentDisplayName` shows in the header line so the user always knows which agent drew the surface.

## Catalogs

v0.1 ships two catalogs: most of the A2UI basic catalog, so existing agents work unchanged, and a small Emacs catalog that is the reason to use this library over a web renderer. The client advertises both in `supportedCatalogIds`.

**Basic catalog mapping** (`https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json`)

| Component | Emacs rendering | v0.1 |
| --- | --- | --- |
| Text | `vui-text`; simple Markdown → faces; `variant` h1–h3 → heading faces | Yes |
| Column, Card | Children stacked; Card adds a thin rule and indent | Yes |
| Row | Children joined on one line; wraps to a column when too wide | Yes |
| List | Column with optional bullets; templates over data | Yes |
| Divider | A rule line in `shadow` face | Yes |
| Button | `vui-button`; `primary` variant in bold | Yes |
| TextField | `vui-field`; multi-line variants open an indirect edit buffer | Yes |
| CheckBox | `vui-checkbox` | Yes |
| ChoicePicker | `vui-select` (single) or checkboxes (multi) | Yes |
| Slider | Numeric field with `-` / `+` keys, range from props | Yes |
| DateTimeInput | Field that opens `org-read-date` | Yes |
| Tabs | Tab titles as buttons; only the selected child rendered | Later |
| Modal | Child surface in a popup window | Later |
| Icon | A small glyph table, else the icon name in brackets | Yes |
| Image | Inline image when `display-images-p` and URL is fetchable; else a link | Later |
| Video, AudioPlayer | Link opened with `browse-url` | Yes (as links) |

**Emacs catalog** (`https://github.com/chazu/a2ui.el/catalogs/emacs/v0.1`)

These reuse A2UI's component and binding model; only the types are new. Each one maps an agent's intent onto something Emacs already does well.

| Component | Props | Rendering |
| --- | --- | --- |
| Section | `title`, `child`, `collapsed` | magit-section style fold with TAB |
| Table | `columns`, `rows` (bound list), `selectable` | vtable, with row selection written to a bound path |
| Diff | `diff` (unified text), `file` | `diff-mode` fontification, read-only; optional Accept / Reject actions |
| Code | `text`, `language` | Fontified with the language's major mode |
| Picker | `options` (bound list), `value` | Button that opens `completing-read`; writes the choice |
| FileRef | `path`, `line` | Button that visits the file at the line |
| OrgText | `text` | Org markup rendered with org faces, read-only |

The catalog is a JSON Schema file (with matching `$id` and `catalogId`) shipped in the package, so agents can be prompted with it, and the core's validator uses it too.

## Transport layer (a2ui-agui.el)

The AG-UI adapter is an SSE client plus an event reducer: it POSTs a `RunAgentInput`, folds the event stream into a thread, and forwards any A2UI payload it finds to the core. Actions go back as the input of the next run.

**HTTP and SSE**

- A `curl --no-buffer -N` subprocess via `make-process`, POSTing JSON and reading `text/event-stream`. A process filter splits frames on blank lines and parses each `data:` line with `json-parse-string`. This avoids url.el's poor streaming support; `plz` with a `:filter` is an acceptable alternative.
- One process per run. `C-g` in the surface buffer, or `a2ui-agui-abort`, kills it.
- Headers (auth tokens) come from a per-agent config that can read `auth-source`.

**Run state**

```elisp
(cl-defstruct a2ui-agui-agent
  url headers thread-id
  messages        ; transcript as AG-UI message objects
  state           ; shared state doc; STATE_SNAPSHOT replaces, STATE_DELTA patches
  tools           ; frontend tools advertised in RunAgentInput
  session         ; the a2ui-session it feeds
  run-process)
```

**Event reducer**

| Event | Handling |
| --- | --- |
| `RUN_STARTED` / `RUN_FINISHED` / `RUN_ERROR` | Mode-line status; errors to `*a2ui-log*` and the echo area |
| `TEXT_MESSAGE_*` | Accumulated into `messages`; optionally echoed to a host transcript via hook |
| `TOOL_CALL_START` / `ARGS` / `END` | Args deltas concatenated; on END, if the tool is `render_a2ui`, the args are applied to the core |
| `TOOL_CALL_RESULT` | Scanned for an A2UI payload (see below) |
| `STATE_SNAPSHOT` / `STATE_DELTA` | Stored; deltas applied with a small RFC 6902 implementation |
| `MESSAGES_SNAPSHOT` | Replaces `messages` |
| `ACTIVITY_*`, `CUSTOM` | Checked for A2UI payloads; else ignored |
| everything else | Logged, ignored |

**Where A2UI rides**

Two paths, both supported:

1. **Frontend tool (preferred).** The client declares a `render_a2ui` tool in `RunAgentInput.tools` whose argument is a list of A2UI messages. The agent "calls" it; Emacs renders. This is pure AG-UI with no vendor conventions, and it works with any framework adapter that supports frontend tools.
2. **Interception.** For agents built with CopilotKit's A2UI middleware, the adapter recognises A2UI operations inside tool results, activity content or a `CUSTOM` event named `a2ui`, and forwards them. The exact shapes are pinned by fixture tests against the CopilotKit and `@ag-ui/a2ui-toolkit` outputs.

**Sending actions back**

The session's `send-action-fn` starts a new run. For path 1, the action JSON becomes the result of the pending `render_a2ui` tool call, so the agent sees it as the tool's answer. For path 2, it is sent the way the agent's middleware expects; that encoder is a variable (`a2ui-agui-action-encoder`) because it differs between stacks. `sendDataModel` metadata rides in `forwardedProps`.

**Interrupts**

If `RUN_FINISHED` carries an interrupt outcome, v0.1 renders each interrupt as a simple A2UI surface (its message plus approve / reject buttons) and resumes with the `resume` array. That reuses the renderer instead of inventing separate approval UI.

## Host integration and public API

In v0.1 each surface gets its own buffer, displayed through `display-buffer` so users control placement with `display-buffer-alist`. Inline surfaces inside another package's transcript are a v0.2 goal, behind the same API.

**User commands**

| Command | What it does |
| --- | --- |
| `a2ui-agui-connect` | Prompt for an agent (from `a2ui-agui-agents`), start a thread |
| `a2ui-agui-send` | Send a user message to the current agent; surfaces appear as it responds |
| `a2ui-agui-abort` | Kill the running run |
| `a2ui-list-surfaces` | tabulated-list of live surfaces; RET to visit, `d` to delete |
| `a2ui-show-log` | Raw protocol log: every message in and out, as pretty JSON |
| `a2ui-replay-file` | Feed a `.jsonl` file of A2UI messages into a local session, no agent needed |

Keys in a surface buffer: TAB / S-TAB between controls, RET to activate, `g` to re-render, `q` to bury, `C-c C-k` to delete the surface and tell the agent.

**Programmatic API (for other packages)**

```elisp
;; Create a session with your own transport
(a2ui-session-create :send-action-fn #'my-send
                     :catalogs '(basic emacs))

;; Feed it messages from anywhere: MCP tool results, ACP, a gptel tool
(a2ui-apply-message session msg)

;; Render a surface into a buffer you own (v0.2: at a marker)
(a2ui-show-surface session "contact_form_1")

;; Extend the Emacs catalog
(a2ui-define-component emacs "Magit" (c surface scope) ...)
(a2ui-define-function emacs "projectRoot" () (project-root (project-current)))
```

**Configuration**

```elisp
(setq a2ui-agui-agents
      '(("local-adk" :url "http://localhost:8000/agent")
        ("work"      :url "https://agents.example.com/run"
                     :headers (("Authorization" . a2ui-auth-from-authinfo)))))
```

The split matters most here: agent-shell, gptel or a home-grown orchestrator can use `a2ui-core` and `a2ui-vui` without ever loading the AG-UI adapter.

## Example: an agent asks for deploy parameters

One full loop through all three layers, using the frontend-tool path. The user asks an agent to deploy a service; the agent needs a target and a replica count before it can act.

1. The user runs `a2ui-agui-send` with "deploy the billing service". The adapter POSTs `RunAgentInput` with the thread's messages and `tools: [render_a2ui]`.
2. The agent streams `RUN_STARTED`, a short `TEXT_MESSAGE_*` ("I need a couple of details"), then a `render_a2ui` tool call whose args stream in as `TOOL_CALL_ARGS` deltas.
3. On `TOOL_CALL_END` the adapter parses the args and applies each message to the core:

   ```json
   {"version":"v0.9","createSurface":{"surfaceId":"deploy_params","catalogId":"https://github.com/chazu/a2ui.el/catalogs/emacs/v0.1"}}
   {"version":"v0.9","updateComponents":{"surfaceId":"deploy_params","components":[
     {"id":"root","component":"Column","children":["env","replicas","diff","go"]},
     {"id":"env","component":"Picker","label":"Environment","options":{"path":"/envs"},"value":{"path":"/form/env"}},
     {"id":"replicas","component":"TextField","label":"Replicas","value":{"path":"/form/replicas"},
      "checks":[{"call":"numeric","args":{"value":{"path":"/form/replicas"},"min":1,"max":20},"message":"1–20"}]},
     {"id":"diff","component":"Diff","diff":{"path":"/plan"}},
     {"id":"go_label","component":"Text","text":"Deploy"},
     {"id":"go","component":"Button","child":"go_label","variant":"primary",
      "action":{"event":{"name":"deploy","context":{"env":{"path":"/form/env"},"replicas":{"path":"/form/replicas"}}}}}]}}
   {"version":"v0.9","updateDataModel":{"surfaceId":"deploy_params","value":{"envs":["staging","prod"],"form":{"env":"staging","replicas":"3"},"plan":"--- a/values.yaml\n+++ b/values.yaml\n..."}}}
   ```
4. The renderer mounts `*a2ui: deploy_params*`: a picker, a validated field, a fontified diff and a Deploy button. The run finishes with the tool call still unanswered.
5. The user picks `prod`, types `5`. Each edit updates `/form/...` locally; no network traffic.
6. RET on Deploy: the core resolves the context and builds `{"action":{"name":"deploy","surfaceId":"deploy_params","sourceComponentId":"go","context":{"env":"prod","replicas":"5"},...}}`.
7. The adapter starts a new run whose messages include that action as the result of the pending `render_a2ui` call. The agent carries on with the deploy and may update the same surface, for example replacing the button with a progress Text.

## Testing

Most of the library is tested without a display or a network, because the core is pure and both the renderer and transport have replayable inputs.

- **Core unit tests** (ERT or buttercup, batch Emacs): JSON Pointer get/set including escapes and relative scopes; each message type; upsert and delete semantics; every v0.1 function; `formatString` parsing edge cases; validation error shapes.
- **Spec conformance fixtures**: the example streams from the A2UI spec and the a2ui-project samples, checked into `test/fixtures/*.jsonl`, replayed through the core with expected final state.
- **Render snapshots**: replay a fixture into a vui-mounted buffer and compare `buffer-string` (plus a face summary) to a golden file. Includes progressive cases: components before root, missing data, dangling child ids.
- **Interaction tests**: drive the rendered buffer with `execute-kbd-macro` (type into a field, RET on a button) and assert the captured outbound action.
- **Transport tests**: recorded SSE streams (`*.sse`) fed into the process filter, split at awkward byte boundaries, asserting the event reducer's state and the A2UI messages forwarded. One recording each from a frontend-tool agent and a CopilotKit A2UI agent.
- **Live smoke test** (manual, CI-optional): the A2UI restaurant-finder sample agent behind an AG-UI endpoint, end to end.

## Risks and open questions

The biggest risks are layout in a text buffer and the unstandardised parts of the A2UI-over-AG-UI binding; both are contained by keeping the core spec-pure and the edges configurable.

| Risk or question | Impact | Mitigation |
| --- | --- | --- |
| Row and nested layouts in a text buffer | Wide rows wrap badly; agents designed for phones look odd | Check vui's layout primitives first; fall back Row → Column under a width threshold; steer agents to the Emacs catalog |
| Re-render cost on each keystroke in large surfaces | Typing lag in long templated lists | Rely on vui reconciliation and keyed children; benchmark a 500-row template in milestone 2 |
| How actions return over AG-UI is not standardised | Works with one stack, breaks with another | Frontend-tool path as default; `a2ui-agui-action-encoder` for others; fixture tests per stack |
| A2UI v1.0 is a candidate | Message or catalog changes | Version-keyed dispatch from day one; track the evolution guide |
| Embedding a surface inside another buffer (agent-shell transcript) | vui demos mount to their own buffer | v0.1 uses dedicated buffers; prototype marker-based mounting before promising inline surfaces |
| Agent spoofs identity via `agentDisplayName` | User trusts a surface from the wrong agent | Header line shows the configured agent name, not the theme field, unless the user opts in |
| Untrusted URLs in Image, Video, `openUrl` | Unexpected network access | Ask before fetching or opening external URLs; allowlist per agent |

**Open questions**

- Should the Emacs catalog be one catalog, or `basic` plus an extension? A2UI negotiates by catalog id, so mixing needs a decision.
- Does vui expose enough of widget.el for multi-line fields and inactive buttons, or do those need small upstream patches?
- Is ACP (agent-shell) a better second transport than MCP for the people most likely to use this?

## Milestones

Four milestones, each ending in something a user can run; the first needs no agent at all.

1. **Core + replay.** `a2ui-core.el` complete for v0.9 messages, pointers, functions and validation; `a2ui-replay-file` renders spec fixtures with Text, Column, Row, Card, Button, TextField and CheckBox.
   - Done when: the spec's contact-form stream renders, edits update the data model, and the button emits the correct action into the log.
2. **Full basic catalog subset + render tests.** Remaining v0.1 basic components, list templates with relative scopes, checks and disabled buttons, golden-file and interaction tests, a 500-row performance check.
   - Done when: every "Yes" row in the basic catalog table passes its snapshot test.
3. **AG-UI transport.** SSE client, event reducer, frontend-tool path, actions as tool results, interrupts as surfaces, recorded-stream tests.
   - Done when: the deploy example runs end to end against a real AG-UI agent.
4. **Emacs catalog + first release.** Section, Table, Diff, Code, Picker, FileRef, OrgText; the catalog JSON Schema published; docs and a demo GIF; MELPA submission.
   - Done when: an agent prompted with the Emacs catalog produces a surface that uses at least three of its components.

After v0.1: inline surfaces at a marker for agent-shell and gptel, an MCP adapter, Tabs and Modal, and the interception path for CopilotKit-style agents if it isn't already covered.

## Implementation notes

Findings from milestone 1 that refine the design above.

- **vui version.** The renderer needs vui.el from MELPA (the 2026 snapshot); the `1.4.0` tag on MELPA-stable predates the external-update API it uses. Eldev pulls from `melpa-unstable`.
- **Rows.** vui's `hstack` cannot set multi-line children side by side, but `vui-flex :wrap` can, by composing the row as text: buttons keep working, editable widgets do not. So a Row is laid out with `vui-flex` (wrapping when too wide), unless something under it is a TextField, CheckBox or ChoicePicker, in which case it stacks as a Column. A justified row of one-line children uses an unwrapped flex, since vui ignores `:justify` when wrapping. The contact form's name row stacks; the spec's track list and data grid stay side by side.
- **Checks.** The v0.9 schema wraps a check as `{condition, message}`, but the spec's own contact-form example puts `call`/`args` on the rule itself. Both shapes are accepted.
- **Outbound messages.** `send-action-fn` receives the whole client-to-server envelope (`{"version", "action"}` or `{"version", "error"}`) plus metadata, so validation errors reach the agent the same way actions do.
- **Versions.** `v0.9` and `v0.9.1` share a handler; the wire format is the same. A message without `version` is treated as v0.9.
- **Regex.** `regex` checks and `validationRegexp` use JavaScript syntax; a translator covers classes, shorthand escapes, groups, alternation, quantifiers and anchors. Lookaround is reported as an error.
- **One package for now.** Eldev builds a single package from `a2ui.el`, so only it carries `Package-Requires`. Splitting into `a2ui-core` / `a2ui-vui` packages is a MELPA-recipe decision for milestone 4.

Milestone 2:

- **Conformance fixtures.** The 44 examples from the spec's basic catalog (`test/fixtures/examples/`) and one fixture per v0.1 component (`test/fixtures/catalog/`) each get a snapshot test: buffer text plus a summary of the `a2ui-*` faces, against `test/golden/`. Only `37_native-grid`, which uses custom components, may report errors. `A2UI_UPDATE_GOLDEN=1 eldev test` rewrites the goldens.
- **Failures wait until touched.** An input's failing checks stay hidden until the user edits it, or until a Button's checks block a submit, which reveals them all. A fresh form no longer opens covered in "required" errors.
- **Inputs.** Single ChoicePicker is a `vui-select` (completing-read); multiple selection is a checkbox per option, laid out in a row for `chips`. Slider is `[-] [value] [+]` with a gauge: `-`/`+` (or arrow keys) on the value step by about a twentieth of the range and RET reads an exact number, clamped. A typed field was avoided because a re-render would rewrite partial input such as `0.`. DateTimeInput is a button that opens `org-read-date` and writes `YYYY-MM-DD`, `HH:MM:SS` or `YYYY-MM-DDTHH:MM:SS` (local time, no zone, like a browser's `datetime-local`), honouring `min`/`max`. `longText` shows the text with an Edit button that opens an `a2ui-edit-mode` buffer (C-c C-c saves, C-c C-k cancels).
- **Media.** Image, Video and AudioPlayer render as links (`a2ui-open-url`: http(s) only, confirmed first). Inline images remain "later".
- **Performance.** `benchmarks/a2ui-bench.el` renders N templated rows of Text plus TextField and types into one. Measured on Emacs 31.1: 500 rows (1000 lines) take ~30 ms to render first and ~60–70 ms per keystroke; 1000 rows take ~90 ms and ~155 ms. Building the vnodes is ~10 ms per 500 rows and linear; the rest is vui's reconciliation, so a per-row memoized component is the lever if long surfaces need it.

Milestone 3 (AG-UI transport, `a2ui-agui.el`):

- **The ecosystem already fixes the A2UI-over-AG-UI binding**, so the transport follows it rather than the sketch above. The frontend tool is `render_a2ui` with the AG-UI toolkits' schema, `{surfaceId, components, data}`, not a list of A2UI messages; the client turns a call into createSurface / updateComponents / updateDataModel. Args holding `a2ui_operations` or `messages` arrays are accepted too.
- **Three ways in.** (1) `render_a2ui` calls, applied on TOOL_CALL_END. (2) `ACTIVITY_SNAPSHOT` / `ACTIVITY_DELTA` with activityType `a2ui-surface` and `content.a2ui_operations`, as the AG-UI A2UI middleware emits; snapshots are cumulative and resend createSurface, which the client skips for existing surfaces. Status-only snapshots (`building`, `retrying`, `failed`) become transcript lines. (3) Tool results whose content is `{"a2ui_operations": [...]}`. The toolkits' basic catalog id (`…/v0_9/basic_catalog.json`) is an alias of the basic catalog.
- **Actions.** AG-UI requires every frontend tool call to be answered before the thread continues, so an open render is answered `{"status":"rendered","surfaceIds":[…]}` before anything new joins the history. A user action is then written as the middleware would write it: an assistant `log_a2ui_event` tool call plus a tool result `User performed action "deploy" on surface … Context: {…}`. Behind that middleware, set `a2ui-agui-action-encoding` (or an agent's `:action-encoding`) to `forwarded-props` to send `forwardedProps.a2uiAction.userAction` instead. `sendDataModel` rides as `forwardedProps.a2uiClientDataModel`.
- **Capabilities** go where CopilotKit puts them: context entries for the catalog list ("A2UI catalog capabilities"), a usage guide for `render_a2ui`, and the component schema (`a2ui-agui-advertise-schema`), plus `forwardedProps.a2uiCatalogAvailable`.
- **Self-correction.** A render that fails validation is answered with `{"status":"failed","errors":[…]}` in an immediate follow-up run, up to `a2ui-agui-render-retries` (2) times in a row. The core now sends validation errors about incoming messages every time; only render-time errors are reported once.
- **Interrupts** become a surface with Approve / Reject; the run resumes with `resume: [{interruptId, status: "resolved", payload: {approved: bool}}]` once every interrupt has an answer.
- **curl.** The URL and headers go to `curl --config -` on stdin, so tokens stay out of `ps`; the body goes through a private temp file. `--fail-with-body` turns HTTP errors into a status line with the server's message. A stream that closes without RUN_FINISHED is reported as truncated. `*_CHUNK` events are expanded into start/content/end.
- **Test agents** live in `examples/agents/`: `deploy_agent.py` (scripted, on the official `ag-ui-protocol` SDK) plays the deploy example including a prod-deploy interrupt; `llm_agent.py` bridges AG-UI to OpenAI chat completions with the client's tools and context; `drive-deploy.el` plays the user in batch Emacs and can record each run's SSE stream. Every RunAgentInput it sent validated against the AG-UI 1.0 JSON Schema (`spec/1.0/schema.json`). The recordings are `test/fixtures/agui/scripted/`; `middleware.sse` follows the middleware's documented event shapes.

Milestone 4 (Emacs catalog and release prep):

- **One superset catalog.** `https://github.com/chazu/a2ui.el/catalogs/emacs/v0.1` holds the basic components plus Section, Table, Diff, Code, Picker, FileRef and OrgText, so one surface can mix them. Tabs and Modal are left out until the renderer draws them, so agents are never offered what only renders as a placeholder. `catalogs/emacs/catalog.json` is generated by `scripts/build-emacs-catalog.py` from the basic catalog. In code the catalog *extends* `basic` (`:parent`): it inherits the basic functions and renderers, and `a2ui-session-top-catalogs` describes only it, since the basic catalog is inside it. Loading `a2ui-emacs` adds it to `a2ui-default-catalogs`.
- **Digests, not schemas.** `a2ui-catalog-digest` writes a line per component (`TextField: label:str value?:str variant?:longText|...`) plus the functions, from the schema; a component may carry its own `x-a2ui-digest` line, as every Emacs component does, to explain behaviour in a few words. The basic digest is ~670 tokens and the Emacs one ~875, against ~4,400 and ~5,500 for the JSON. AG-UI runs now send the digest (`a2ui-agui-catalog-detail`, `schema` restores the middleware's format), and `render_a2ui` defaults to the most capable catalog.
- **Components.** Section folds with RET or TAB, keeping its state in the data model when `collapsed` is bound and in renderer-local state otherwise. Table renders through `vui-table`; selection writes `rowKey` values (or indices), and `rowAction` resolves its context against the row, so an agent can say `{"path": "name"}` once for every row. Diff, Code and OrgText are fontified in a temp buffer by the right major mode with mode hooks delayed (no language servers), cached; Code only trusts a listed language or a major mode derived from `prog-mode`, `text-mode` or `conf-mode`, so an agent cannot toggle an arbitrary `*-mode`. OrgText strips the markup Org hides, leaving the prose with Org's faces. FileRef resolves relative paths against the session's new `directory`.
- **Release prep.** GPL-3.0 LICENSE, README, CHANGELOG, Maintainer/SPDX headers, a GitHub Actions matrix (Emacs 29.1–snapshot) on Eldev, and a MELPA recipe in `recipes/a2ui` (`:files (:defaults "catalogs")`). The package tarball holds the six libraries and both catalogs; installed with `package-install-file` into a clean Emacs it finds its catalogs and renders `examples/code-review.jsonl`. `while-let` (Emacs 30) was replaced to keep the 29.1 minimum honest.
- **Done-check, against Claude.** `examples/agents/claude_agent.py` bridges AG-UI to the Claude Code CLI (`claude -p`, tools, settings and hooks off): the client's context becomes the system prompt and a structured `{say, render?}` reply becomes a real `render_a2ui` call. `examples/agents/drive-catalog.el` asks for a reviewable change without naming components, counts the Emacs component types drawn, then presses Approve. With the first digest Sonnet used only Diff (and Text, TextField): the digest said how each component works but not when to reach for it. After adding a purpose to each Emacs line and the catalog's description as a header (~80 tokens), two runs out of two used Diff, Section and OrgText, rendered valid on the first try, and answered the Approve action by updating the same surface. A run cost about $0.01–0.03 after the first ($0.20, cache creation).
- **Open:** the demo GIF needs a graphical Emacs; `examples/code-review.jsonl` is the replayable stand-in. MELPA submission needs the GitHub repo published and a tag.
