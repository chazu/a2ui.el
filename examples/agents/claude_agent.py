# /// script
# requires-python = ">=3.10"
# dependencies = ["ag-ui-protocol>=1.0.0", "fastapi", "uvicorn"]
# ///
"""A Claude-backed AG-UI agent for trying a2ui.el against a real model.

Each run asks the Claude Code CLI (`claude -p`, using your login) for a
structured reply, {say, render?}, and streams it back as AG-UI: `say`
as a text message, `render` as a call to the client's frontend tool
render_a2ui.  The client's context (catalog ids, the render guide and
the catalog digest) goes into the system prompt, so the model writes
components from the catalog the client advertises.  Claude Code's own
tools, settings and hooks are switched off.

    uv run examples/agents/claude_agent.py     # serves http://127.0.0.1:8772/

CLAUDE_MODEL picks the model (default sonnet); CLAUDE_BIN the binary.
"""

import asyncio
import json
import os
import uuid

import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse

from ag_ui.core import (
    PROTOCOL_VERSION,
    RunAgentInput,
    RunErrorEvent,
    RunFinishedEvent,
    RunFinishedSuccessOutcome,
    RunStartedEvent,
    TextMessageContentEvent,
    TextMessageEndEvent,
    TextMessageStartEvent,
    ToolCallArgsEvent,
    ToolCallEndEvent,
    ToolCallStartEvent,
)
from ag_ui.encoder import EventEncoder

MODEL = os.environ.get("CLAUDE_MODEL", "sonnet")
CLAUDE = os.environ.get("CLAUDE_BIN", "claude")

SYSTEM = """You are an assistant inside the user's Emacs.  Besides talking, you can show the user an interactive surface, rendered natively in Emacs, by filling in `render`; leave it out when words are enough.
Prefer a surface whenever the user must review, choose or fill something in, and use the most specific components the catalog offers.
When a message says the user performed an action on a surface, act on it: say what you did in a sentence and, if useful, render the same surfaceId again to update it.
Keep `say` to one or two sentences."""

REPLY_SCHEMA = {
    "type": "object",
    "properties": {
        "say": {"type": "string", "description": "What to tell the user."},
        "render": {
            "type": "object",
            "description": "Arguments for render_a2ui, or omit to show nothing.",
            "properties": {
                "surfaceId": {"type": "string"},
                "components": {"type": "array", "items": {"type": "object"}},
                "data": {"type": "object"},
            },
            "required": ["surfaceId", "components"],
        },
    },
    "required": ["say"],
}

app = FastAPI(title="a2ui.el Claude agent")


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(getattr(p, "text", "") or "" for p in content)
    return ""


def transcript(data: RunAgentInput):
    """The thread as plain text, oldest first."""
    lines = []
    for m in data.messages:
        if m.role == "user":
            lines.append(f"User: {text_of(m.content)}")
        elif m.role == "assistant":
            if text_of(m.content):
                lines.append(f"Assistant: {text_of(m.content)}")
            for tc in m.tool_calls or []:
                if tc.function.name == "render_a2ui":
                    lines.append(f"Assistant rendered: {tc.function.arguments}")
        elif m.role == "tool":
            lines.append(f"Tool result: {text_of(m.content)}")
    return "\n\n".join(lines)


def system_prompt(data: RunAgentInput):
    context = "\n\n".join(f"## {c.description}\n{c.value}" for c in (data.context or []))
    return SYSTEM + ("\n\n" + context if context else "")


async def ask_claude(data: RunAgentInput):
    """Run claude -p on the thread; return its structured reply."""
    proc = await asyncio.create_subprocess_exec(
        CLAUDE, "-p", "--output-format", "json", "--model", MODEL,
        "--tools", "", "--setting-sources", "", "--no-session-persistence",
        "--system-prompt", system_prompt(data),
        "--json-schema", json.dumps(REPLY_SCHEMA),
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE)
    out, err = await proc.communicate(
        (transcript(data) + "\n\nReply to the last message.").encode())
    if proc.returncode != 0:
        raise RuntimeError(err.decode()[-500:] or f"claude exited {proc.returncode}")
    result = json.loads(out)
    if result.get("is_error") or "structured_output" not in result:
        raise RuntimeError(str(result.get("result"))[:500])
    return result["structured_output"], result.get("total_cost_usd")


async def run(data: RunAgentInput, encoder: EventEncoder):
    yield encoder.encode(RunStartedEvent(thread_id=data.thread_id, run_id=data.run_id,
                                         protocol_version=PROTOCOL_VERSION))
    try:
        reply, cost = await ask_claude(data)
        print(f"run {data.run_id[:8]}: model={MODEL} cost=${cost}", flush=True)
        message_id = str(uuid.uuid4())
        say = reply.get("say") or ""
        if say:
            yield encoder.encode(TextMessageStartEvent(message_id=message_id, role="assistant"))
            for i in range(0, len(say), 40):
                yield encoder.encode(TextMessageContentEvent(message_id=message_id, delta=say[i:i + 40]))
            yield encoder.encode(TextMessageEndEvent(message_id=message_id))
        pending = []
        if reply.get("render"):
            call_id = "call_" + uuid.uuid4().hex[:12]
            args = json.dumps(reply["render"])
            yield encoder.encode(ToolCallStartEvent(tool_call_id=call_id, tool_call_name="render_a2ui",
                                                    parent_message_id=message_id))
            for i in range(0, len(args), 400):
                yield encoder.encode(ToolCallArgsEvent(tool_call_id=call_id, delta=args[i:i + 400]))
            yield encoder.encode(ToolCallEndEvent(tool_call_id=call_id))
            pending.append(call_id)
        yield encoder.encode(RunFinishedEvent(
            thread_id=data.thread_id, run_id=data.run_id,
            outcome=RunFinishedSuccessOutcome(pending_tool_call_ids=pending or None)))
    except Exception as err:  # report, rather than drop the stream
        yield encoder.encode(RunErrorEvent(message=str(err), code=type(err).__name__))


@app.post("/")
async def agent(data: RunAgentInput, request: Request):
    encoder = EventEncoder(accept=request.headers.get("accept"))
    return StreamingResponse(run(data, encoder), media_type=encoder.get_content_type())


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("PORT", "8772")))
