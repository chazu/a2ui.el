# /// script
# requires-python = ">=3.10"
# dependencies = ["ag-ui-protocol>=1.0.0", "fastapi", "uvicorn", "openai"]
# ///
"""A model-backed AG-UI agent for trying a2ui.el against a real LLM.

It bridges AG-UI to OpenAI chat completions: the client's tools
(render_a2ui) and context (the A2UI catalog, schema and usage guide)
are passed to the model as they are, and the model's streamed text
and tool calls come back as AG-UI events.  Every tool is a frontend
tool, so the run ends after the model calls one and the client
answers in the next run.

    OPENAI_API_KEY=... uv run examples/agents/llm_agent.py   # http://127.0.0.1:8771/

OPENAI_MODEL picks the model (default gpt-4.1-mini).  The system
prompt casts it as a deployment assistant, for the deploy example.
"""

import json
import os
import uuid

import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
from openai import AsyncOpenAI

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

MODEL = os.environ.get("OPENAI_MODEL", "gpt-4.1-mini")

SYSTEM = """You are a deployment assistant working inside the user's Emacs.
You can deploy the services billing, search and auth to the environments staging or prod, with 1 to 20 replicas.
When the user asks for a deploy and you lack parameters, call render_a2ui once to show a form that collects them (with sensible defaults and validation), then stop and wait for the user.
When a log_a2ui_event result reports the user's action, carry out the deploy (pretend it succeeds), say so in one sentence, and call render_a2ui with the same surfaceId to replace the form with a short status.
Keep replies to one or two sentences."""

app = FastAPI(title="a2ui.el LLM agent")
client = AsyncOpenAI()


def text_of(content):
    """Flatten AG-UI message content to a string."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(getattr(p, "text", "") or "" for p in content)
    return ""


def to_openai(data: RunAgentInput):
    """The system prompt plus the thread, as chat completion messages."""
    context = "\n\n".join(f"## {c.description}\n{c.value}" for c in (data.context or []))
    messages = [{"role": "system", "content": SYSTEM + ("\n\n" + context if context else "")}]
    for m in data.messages:
        if m.role in ("user", "system", "developer"):
            messages.append({"role": "user" if m.role == "user" else "system",
                             "content": text_of(m.content)})
        elif m.role == "assistant":
            msg = {"role": "assistant", "content": text_of(m.content) or None}
            if m.tool_calls:
                msg["tool_calls"] = [{"id": tc.id, "type": "function",
                                      "function": {"name": tc.function.name,
                                                   "arguments": tc.function.arguments or "{}"}}
                                     for tc in m.tool_calls]
            messages.append(msg)
        elif m.role == "tool":
            messages.append({"role": "tool", "tool_call_id": m.tool_call_id,
                             "content": text_of(m.content)})
    return messages


def to_tools(data: RunAgentInput):
    return [{"type": "function",
             "function": {"name": t.name, "description": t.description,
                          "parameters": t.parameters or {"type": "object"}}}
            for t in (data.tools or [])]


async def run(data: RunAgentInput, encoder: EventEncoder):
    yield encoder.encode(RunStartedEvent(thread_id=data.thread_id, run_id=data.run_id,
                                         protocol_version=PROTOCOL_VERSION))
    message_id = str(uuid.uuid4())
    text_open = False
    calls = {}  # index -> tool call id
    try:
        stream = await client.chat.completions.create(
            model=MODEL, messages=to_openai(data), tools=to_tools(data) or None, stream=True)
        async for chunk in stream:
            if not chunk.choices:
                continue
            delta = chunk.choices[0].delta
            if delta.content:
                if not text_open:
                    text_open = True
                    yield encoder.encode(TextMessageStartEvent(message_id=message_id, role="assistant"))
                yield encoder.encode(TextMessageContentEvent(message_id=message_id, delta=delta.content))
            for tc in delta.tool_calls or []:
                if tc.index not in calls:
                    if text_open:
                        text_open = False
                        yield encoder.encode(TextMessageEndEvent(message_id=message_id))
                    calls[tc.index] = tc.id or f"call_{uuid.uuid4().hex[:12]}"
                    yield encoder.encode(ToolCallStartEvent(tool_call_id=calls[tc.index],
                                                            tool_call_name=tc.function.name,
                                                            parent_message_id=message_id))
                if tc.function and tc.function.arguments:
                    yield encoder.encode(ToolCallArgsEvent(tool_call_id=calls[tc.index],
                                                           delta=tc.function.arguments))
        if text_open:
            yield encoder.encode(TextMessageEndEvent(message_id=message_id))
        for call_id in calls.values():
            yield encoder.encode(ToolCallEndEvent(tool_call_id=call_id))
        yield encoder.encode(RunFinishedEvent(
            thread_id=data.thread_id, run_id=data.run_id,
            outcome=RunFinishedSuccessOutcome(pending_tool_call_ids=list(calls.values()) or None)))
    except Exception as err:  # report, rather than drop the stream
        yield encoder.encode(RunErrorEvent(message=str(err), code=type(err).__name__))


@app.post("/")
async def agent(data: RunAgentInput, request: Request):
    encoder = EventEncoder(accept=request.headers.get("accept"))
    return StreamingResponse(run(data, encoder), media_type=encoder.get_content_type())


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("PORT", "8771")))
