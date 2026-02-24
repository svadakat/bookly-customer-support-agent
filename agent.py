"""
Bookly customer support agent — powered by Snowflake Cortex.

Uses a pre-created Cortex Agent (defined via CREATE AGENT in snowflake_setup.sql)
that orchestrates:
  - Cortex Analyst (structured order queries via semantic model)
  - Cortex Search (unstructured policy lookups via search service)
  - Custom tool (InitiateReturn stored procedure for returns)

All instructions, tools, and tool resources are configured in the agent object
itself — no inline tool definitions needed here.
"""

import json
import os
from dataclasses import dataclass, field

import requests
import sseclient
from dotenv import load_dotenv
from langsmith import traceable
from langsmith.run_helpers import trace as ls_trace

load_dotenv()

SNOWFLAKE_PAT = os.getenv("SNOWFLAKE_PAT", "")
SNOWFLAKE_ACCOUNT_URL = os.getenv("SNOWFLAKE_ACCOUNT_URL", "")
AGENT_DATABASE = os.getenv("AGENT_DATABASE", "BOOKLY")
AGENT_SCHEMA = os.getenv("AGENT_SCHEMA", "SUPPORT")
AGENT_NAME = os.getenv("AGENT_NAME", "BOOKLY_SUPPORT_AGENT")


@dataclass
class StreamedChunk:
    """A piece of the agent's streamed response."""
    event_type: str
    text: str = ""
    status: str = ""
    data: dict = field(default_factory=dict)


class CortexAgent:
    """Manages a conversation with a pre-created Snowflake Cortex Agent."""

    def __init__(self):
        if not SNOWFLAKE_PAT or not SNOWFLAKE_ACCOUNT_URL:
            raise RuntimeError(
                "SNOWFLAKE_PAT and SNOWFLAKE_ACCOUNT_URL must be set in .env. "
                "See README for setup instructions."
            )
        if not AGENT_NAME:
            raise RuntimeError(
                "AGENT_NAME must be set in .env. Create the agent via "
                "snowflake_setup.sql before running the app."
            )
        self.messages: list[dict] = []
        self.api_url = (
            f"https://{SNOWFLAKE_ACCOUNT_URL}"
            f"/api/v2/databases/{AGENT_DATABASE}"
            f"/schemas/{AGENT_SCHEMA}"
            f"/agents/{AGENT_NAME}:run"
        )
        print(f"[CortexAgent] API URL: {self.api_url}")

    def _build_request_body(self) -> dict:
        return {
            "messages": self.messages,
            "stream": True,
        }

    @traceable(run_type="llm", name="cortex_agent_api")
    def _call_api(self, body: dict) -> requests.Response:
        resp = requests.post(
            url=self.api_url,
            json=body,
            headers={
                "Authorization": f"Bearer {SNOWFLAKE_PAT}",
                "Content-Type": "application/json",
            },
            stream=True,
        )
        if resp.status_code >= 400:
            raise RuntimeError(
                f"Cortex Agent API error {resp.status_code}: {resp.text}"
            )
        return resp

    def chat_stream(self, user_message: str):
        """
        Send a user message and yield StreamedChunk objects as the
        Cortex Agent responds. Updates internal message history.
        Traced via LangSmith when LANGCHAIN_TRACING_V2=true.
        """
        self.messages.append({
            "role": "user",
            "content": [{"type": "text", "text": user_message}],
        })

        with ls_trace(
            name="chat_stream",
            run_type="chain",
            inputs={"user_message": user_message},
        ) as run:
            full_text = ""
            tools_used = []

            body = self._build_request_body()
            response = self._call_api(body)
            events = sseclient.SSEClient(response).events()

            for event in events:
                if not event.data or not event.data.strip():
                    continue
                try:
                    data = json.loads(event.data)
                except json.JSONDecodeError:
                    continue

                if event.event == "response.text.delta":
                    full_text += data.get("text", "")
                    yield StreamedChunk(
                        event_type="text_delta",
                        text=data.get("text", ""),
                    )

                elif event.event == "response.thinking.delta":
                    yield StreamedChunk(
                        event_type="thinking_delta",
                        text=data.get("text", ""),
                    )

                elif event.event == "response.status":
                    yield StreamedChunk(
                        event_type="status",
                        status=data.get("message", ""),
                    )

                elif event.event == "response.tool_use":
                    tools_used.append(data.get("name", "unknown"))
                    yield StreamedChunk(
                        event_type="tool_use",
                        data=data,
                    )

                elif event.event == "response.tool_result":
                    yield StreamedChunk(
                        event_type="tool_result",
                        data=data,
                    )

                elif event.event == "response":
                    self.messages.append(data)
                    yield StreamedChunk(
                        event_type="done",
                        data=data,
                    )

                elif event.event == "error":
                    full_text = f"Error: {data.get('message', 'Unknown error')}"
                    yield StreamedChunk(
                        event_type="error",
                        text=data.get("message", "Unknown error"),
                    )

            run.end(outputs={
                "response": full_text,
                "tools_used": tools_used,
            })
