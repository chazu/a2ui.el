# Changelog

## 0.1.0 (unreleased)

First release.

- A2UI v0.9 (and v0.9.1) protocol core: surfaces, data models, JSON Pointer with relative scopes, every basic-catalog function, validation errors returned to the agent.
- vui.el renderer for the basic catalog, minus Tabs and Modal.
- Emacs catalog: Section, Table, Diff, Code, Picker, FileRef, OrgText, as a superset of the basic catalog.
- Catalog digests for token-efficient prompting.
- AG-UI client: SSE over curl, `render_a2ui` frontend tool, A2UI middleware activity snapshots, `a2ui_operations` tool results, actions, interrupts, automatic render retries.
- `a2ui-replay-file`, protocol and AG-UI logs.
- Host integrations sharing one tool layer (`a2ui-tools`: render_a2ui, update_a2ui, a2ui_catalog, a2ui_await_action):
  - gptel, as native async tools (`a2ui-gptel-enable`);
  - an MCP server inside Emacs, for Claude Code and Codex in a terminal (`a2ui-mcp-start`);
  - agent-shell, through that server, with button presses submitted as prompts and a2ui's tools auto-approved (`a2ui-agent-shell-setup`).
- Common model mistakes in components (a `props` wrapper, inline children) are repaired before validation.
