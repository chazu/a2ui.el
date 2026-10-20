# Changelog

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
