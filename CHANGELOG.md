# Changelog

## 0.1.2 (2026-10-20)

- Typing in a text field no longer renders the whole surface again on each key, unless something else on the surface shows the value. In a 1000-row form a keystroke went from ~150–300 ms to ~1 ms.
- A Row checks for editable widgets beneath it in linear time.
- The AG-UI client refuses a URL or header holding a line break, which would otherwise add a line to curl's config.
- A field that a surface shows twice (two Lists templating the same items) shows what is typed in either copy.
- A `validationRegexp` Emacs cannot run, such as one with lookahead, is reported to the agent and passes, instead of turning the field into an error.
- A Modal templated over a list shows the item whose trigger was pressed, not the first one opened.
- An `a2ui_await_action` whose MCP client gave up no longer takes the user's next action; it waits for the next await.
- AG-UI activity deltas apply only their new operations, so a resent data update no longer undoes what the user typed, and a long stream isn't validated over and over.
- A JSON Patch (STATE_DELTA, ACTIVITY_DELTA) that fails part way leaves the state as it was.
- Aborting an AG-UI run no longer reports a failed request first.
- agent-shell keeps surfaces that arrive before the shell's first prompt, and shows them at the next turn's end.
- Fetched images are kept to 50 MB, oldest first, and a failed fetch is tried again after a minute.
- The SSE parser scans each byte once, however many chunks an event arrives in.
- The protocol and AG-UI logs keep their last `a2ui-log-max-size` characters (2,000,000 by default).

## 0.1.1 (2026-10-20)

- OrgText keeps link descriptions on Emacs 29: Org 9.6 marks them with an `invisible` value it doesn't hide, and they were stripped with the link targets.
- Tests no longer depend on the local time zone, and the CI matrix (Emacs 29.1, 29.4, 30.1, snapshot, checkdoc on 30.1) passes. Emacs 32 lays out emoji such as ☀️ two columns wide, so one snapshot has an Emacs 32 golden.

## 0.1.0 (2026-10-20)

First release.

- A2UI v0.9 (and v0.9.1) protocol core: surfaces, data models, JSON Pointer with relative scopes, every basic-catalog function, validation errors returned to the agent.
- vui.el renderer for the whole basic catalog. Tabs switch locally, and a Modal's content opens in a popup window. Images show inline, asking before fetching (`a2ui-vui-inline-images`).
- Emacs catalog: Section, Table, Diff, Code, Picker, FileRef, OrgText, as a superset of the basic catalog.
- Catalog digests for token-efficient prompting.
- AG-UI client: SSE over curl, `render_a2ui` frontend tool, A2UI middleware activity snapshots, `a2ui_operations` tool results, actions, interrupts, automatic render retries.
- `a2ui-replay-file`, `a2ui-list-surfaces`, protocol and AG-UI logs.
- A demo GIF in the README, recorded from the real renderer by `scripts/demo-gif.el`.
- Host integrations sharing one tool layer (`a2ui-tools`: render_a2ui, update_a2ui, a2ui_catalog, a2ui_await_action):
  - gptel, as native async tools (`a2ui-gptel-enable`);
  - an MCP server inside Emacs, for Claude Code and Codex in a terminal (`a2ui-mcp-start`);
  - agent-shell, through that server, with button presses submitted as prompts and a2ui's tools auto-approved (`a2ui-agent-shell-setup`).
- Common model mistakes in components (a `props` wrapper, inline children) are repaired before validation.
- Validation checks the shape of actions and of dynamic values, so a string `event` or a `{"bind": …}` object comes back to the model as an error instead of a dead button.
- a2ui_await_action returns at once for a surface that doesn't exist or failed to render, and ends with `closed` when you delete the surface.
- Inline surfaces: `a2ui-vui-insert-surface` draws a live surface at a position in any buffer, which stays editable around it. `a2ui-gptel-inline-surfaces` and `a2ui-agent-shell-inline-surfaces` put surfaces in the chat or shell. A session's `display-fn` decides where new surfaces go.
- gptel: free-form object arguments (`data`) travel as JSON text, since gptel closes object schemas. A press waits while gptel runs tools, not only while a request is open.
