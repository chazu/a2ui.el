# /// script
# requires-python = ">=3.10"
# dependencies = ["ag-ui-protocol>=1.0.0", "fastapi", "uvicorn"]
# ///
"""A scripted AG-UI agent that plays the deploy example from DESIGN.md.

It needs no model: it answers by rule, so its event streams are
reproducible and can be recorded as test fixtures.

    uv run examples/agents/deploy_agent.py          # serves http://127.0.0.1:8770/

1. "deploy the billing service": it explains, then calls the frontend
   tool render_a2ui with a form (environment, replicas, Deploy button).
2. The Deploy action arrives as a log_a2ui_event tool result.  Staging
   deploys at once; prod first ends the run with an interrupt asking
   for confirmation.
3. On resume it reports the outcome and updates the same surface.
"""

import json
import os
import uuid

import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse

from ag_ui.core import (
    PROTOCOL_VERSION,
    Interrupt,
    RunAgentInput,
    RunFinishedEvent,
    RunFinishedInterruptOutcome,
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

app = FastAPI(title="a2ui.el deploy agent")

SURFACE = "deploy_params"


def form_components():
    """The deploy form, in the basic catalog."""
    return [
        {"id": "root", "component": "Column", "children": ["title", "env", "replicas", "go"]},
        {"id": "title", "component": "Text", "variant": "h3", "text": "Deploy billing"},
        {"id": "env", "component": "ChoicePicker", "label": "Environment",
         "options": [{"label": "Staging", "value": "staging"}, {"label": "Production", "value": "prod"}],
         "value": {"path": "/form/env"}},
        {"id": "replicas", "component": "TextField", "label": "Replicas",
         "value": {"path": "/form/replicas"},
         "checks": [{"condition": {"call": "numeric",
                                   "args": {"value": {"path": "/form/replicas"}, "min": 1, "max": 20}},
                     "message": "Enter 1 to 20 replicas."}]},
        {"id": "go_label", "component": "Text", "text": "Deploy"},
        {"id": "go", "component": "Button", "child": "go_label", "variant": "primary",
         "action": {"event": {"name": "deploy",
                              "context": {"env": {"path": "/form/env"},
                                          "replicas": {"path": "/form/replicas"}}}},
         "checks": [{"condition": {"call": "numeric",
                                   "args": {"value": {"path": "/form/replicas"}, "min": 1, "max": 20}},
                     "message": "Fix the replica count first."}]},
    ]


def done_components(text):
    """The surface after the deploy: the title and a status line."""
    return [
        {"id": "root", "component": "Column", "children": ["title", "status"]},
        {"id": "title", "component": "Text", "variant": "h3", "text": "Deploy billing"},
        {"id": "status", "component": "Text", "text": text},
    ]


class Run:
    """Collects the events of one run."""

    def __init__(self, data: RunAgentInput, encoder: EventEncoder):
        self.data = data
        self.encoder = encoder
        self.frames = [encoder.encode(RunStartedEvent(
            thread_id=data.thread_id, run_id=data.run_id, protocol_version=PROTOCOL_VERSION))]
        self.pending_calls = []

    def say(self, text):
        mid = str(uuid.uuid4())
        self.frames.append(self.encoder.encode(TextMessageStartEvent(message_id=mid, role="assistant")))
        # Stream in a few pieces, as a model would.
        for i in range(0, len(text), 24):
            self.frames.append(self.encoder.encode(
                TextMessageContentEvent(message_id=mid, delta=text[i:i + 24])))
        self.frames.append(self.encoder.encode(TextMessageEndEvent(message_id=mid)))
        return mid

    def render(self, components, data=None, parent=None):
        call_id = "call_" + uuid.uuid4().hex[:12]
        args = {"surfaceId": SURFACE, "components": components}
        if data is not None:
            args["data"] = data
        text = json.dumps(args)
        self.frames.append(self.encoder.encode(ToolCallStartEvent(
            tool_call_id=call_id, tool_call_name="render_a2ui",
            parent_message_id=parent or str(uuid.uuid4()))))
        for i in range(0, len(text), 200):
            self.frames.append(self.encoder.encode(ToolCallArgsEvent(tool_call_id=call_id,
                                                                     delta=text[i:i + 200])))
        self.frames.append(self.encoder.encode(ToolCallEndEvent(tool_call_id=call_id)))
        self.pending_calls.append(call_id)

    def finish(self, interrupt=None):
        outcome = (RunFinishedInterruptOutcome(interrupts=[interrupt]) if interrupt
                   else RunFinishedSuccessOutcome(pending_tool_call_ids=self.pending_calls or None))
        self.frames.append(self.encoder.encode(RunFinishedEvent(
            thread_id=self.data.thread_id, run_id=self.data.run_id, outcome=outcome)))
        return self.frames


def last_action(data: RunAgentInput):
    """The user action in the newest tool result, if that is what came last."""
    calls = {}
    for m in data.messages:
        for tc in getattr(m, "tool_calls", None) or []:
            calls[tc.id] = tc
    for m in reversed(data.messages):
        if m.role == "user":
            return None
        if m.role == "tool" and m.tool_call_id in calls:
            call = calls[m.tool_call_id]
            if call.function.name == "log_a2ui_event":
                return json.loads(call.function.arguments)
    return None


def last_user_text(data: RunAgentInput):
    for m in reversed(data.messages):
        if m.role == "user":
            return m.content if isinstance(m.content, str) else ""
    return ""


def env_of(context):
    env = context.get("env")
    return env[0] if isinstance(env, list) and env else env


def respond(data: RunAgentInput, encoder: EventEncoder):
    run = Run(data, encoder)
    if data.resume:
        entry = data.resume[0]
        payload = entry.payload or {}
        if entry.status == "resolved" and payload.get("approved"):
            run.say("Approved. Deploying billing to prod.")
            run.render(done_components("✓ Deployed billing to prod."))
        else:
            run.say("Cancelled; nothing was deployed.")
            run.render(done_components("✗ Deployment cancelled."))
        return run.finish()

    action = last_action(data)
    if action and action.get("name") == "deploy":
        context = action.get("context") or {}
        env, replicas = env_of(context), context.get("replicas")
        if env == "prod":
            run.say(f"Production needs a confirmation before I deploy {replicas} replicas.")
            return run.finish(Interrupt(
                id="confirm-" + data.run_id[:8], reason="confirmation",
                message=f"Deploy billing to prod with {replicas} replicas?"))
        run.say(f"Deploying billing to {env} with {replicas} replicas.")
        run.render(done_components(f"✓ Deployed billing to {env} ({replicas} replicas)."))
        return run.finish()

    if "deploy" in last_user_text(data).lower():
        parent = run.say("I need a couple of details before I deploy billing.")
        run.render(form_components(), {"form": {"env": ["staging"], "replicas": "3"}}, parent)
        return run.finish()

    run.say("Ask me to deploy the billing service.")
    return run.finish()


@app.post("/")
async def agent(data: RunAgentInput, request: Request):
    encoder = EventEncoder(accept=request.headers.get("accept"))
    frames = respond(data, encoder)

    async def stream():
        for frame in frames:
            yield frame

    return StreamingResponse(stream(), media_type=encoder.get_content_type())


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("PORT", "8770")))
