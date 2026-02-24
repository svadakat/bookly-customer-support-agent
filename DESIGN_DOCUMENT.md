# Bookly Support Agent — Design Document

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────┐
│              Streamlit Chat UI (app.py)               │
│   st.chat_input · st.chat_message · st.session_state │
└──────────────────┬───────────────────────────────────┘
                   │ REST API (SSE streaming)
┌──────────────────▼───────────────────────────────────┐
│           Cortex Agent REST API                       │
│   Orchestration · Multi-turn context · Tool routing  │
└──────┬───────────────────┬───────────────┬───────────┘
       │                   │               │
┌──────▼──────┐  ┌─────────▼────────┐  ┌───▼──────────────┐
│  Cortex     │  │  Cortex Search   │  │  Custom Tool     │
│  Analyst    │  │ (Unstructured)   │  │ (Stored Proc)    │
│ (Structured)│  │                  │  │                  │
│ NL → SQL    │  │ Semantic+keyword │  │ INITIATE_RETURN  │
│  → Results  │  │ search policies  │  │ → validate order │
└──────┬──────┘  └─────────┬────────┘  │ → create RMA     │
       │                   │           │ → write RETURNS   │
┌──────▼──────┐  ┌─────────▼────────┐  └───┬──────────────┘
│  ORDERS     │  │  POLICIES        │      │
│  table      │  │  table (via      │  ┌───▼──────────────┐
│             │  │  Search service) │  │  RETURNS table   │
└─────────────┘  └──────────────────┘  └──────────────────┘
```

**Components:**

| Component | Role |
|---|---|
| **Streamlit Chat UI** | OSS web interface using `st.chat_message`, `st.chat_input`, and SSE streaming for real-time token display. Session state persists conversation across reruns. |
| **Cortex Agent API** | Snowflake's stateless REST endpoint that orchestrates across tools. Decides which tool to invoke based on user intent, manages conversation context, and streams responses as Server-Sent Events. |
| **Cortex Analyst** | Converts natural language questions about orders into SQL queries using a semantic model (`bookly_orders_semantic_model.yaml`). Achieves high accuracy through domain-specific column descriptions, synonyms, and sample values. |
| **Cortex Search** | Hybrid search (semantic + keyword) over the `POLICIES` table. Indexed on `policy_text` with attributes for `topic` and `policy_title`. Returns relevance-ranked results with source attribution. |
| **Custom Tool (`InitiateReturn`)** | A Snowflake stored procedure exposed as a Cortex Agent custom tool. Validates that the order exists, is in "delivered" status, and is within the 30-day return window. On success, inserts an RMA record into the `RETURNS` table and returns shipping instructions. On failure, returns a descriptive error. This is the **agentic action** — the agent doesn't just answer questions, it takes a real action with side effects. |
| **Snowflake Tables** | `ORDERS` stores structured order data (one row per line item, queried via Cortex Analyst). `RETURNS` stores RMA records created by the stored procedure. `POLICIES` stores policy documents indexed by Cortex Search. All are standard Snowflake tables. |

**Data flow for a single turn:**
1. User types a message in Streamlit's chat input.
2. The app sends the message (plus conversation history) to the Cortex Agent REST API via HTTPS.
3. The Agent's orchestration model decides which tool(s) to invoke:
   - Order questions → Cortex Analyst generates SQL, executes it against `ORDERS`, returns structured results.
   - Policy questions → Cortex Search retrieves relevant policy text from the search index.
   - Return requests → Agent gathers order ID + reason, then calls `InitiateReturn` stored procedure.
   - Ambiguous intent → Agent asks a clarifying question (no tool call).
4. The Agent synthesizes tool results into a natural language response, streamed back as SSE events.
5. Streamlit renders tokens in real time (typewriter effect) and saves the final response to session state.

---

## 2. Conversation & Decision Design

### Intent Recognition & Tool Routing

The Cortex Agent uses an LLM orchestrator to route between tools. Rather than a separate intent classifier, routing is driven by:

1. **Tool descriptions** — each tool has a natural language description that tells the orchestrator when to use it (e.g., "Queries the Bookly orders database for order status, tracking, items...").
2. **Orchestration instructions** — explicit rules like "For policy questions about returns, shipping, refunds... use the Cortex Search tool."
3. **Semantic model metadata** — column synonyms in the YAML (e.g., `"where is my order"` maps to `ORDER_STATUS`) help Cortex Analyst match informal language to the right data.

**Why this approach:** Snowflake's Cortex Agent handles orchestration natively — it breaks a question into sub-tasks, selects the right tool, and iterates if needed. This eliminates the need to build and maintain a custom intent classifier or tool-calling loop.

### Decision Ladder: Answer, Clarify, or Act

The orchestration and response instructions encode a decision hierarchy:

1. **Is information missing?** → Ask a clarifying question.
   - "I need help with my order" → "Sure! Would you like a status update, or do you need to make a change or return?"

2. **Is the question about order data?** → Route to Cortex Analyst.
   - "Where is ORD-1042?" → Analyst generates `SELECT * FROM ORDERS WHERE ORDER_ID = 'ORD-1042'` → Agent formats the result.

3. **Is the question about policies?** → Route to Cortex Search.
   - "How long does shipping take?" → Search retrieves the shipping policy → Agent summarizes.

4. **Is the customer requesting an action (return)?** → Use the custom tool.
   - "I want to return order ORD-1103, the book was damaged" → Agent calls `InitiateReturn(ORD-1103, damaged)` stored procedure → procedure validates eligibility, creates RMA, returns instructions → Agent relays the result.
   - If the order isn't eligible, the procedure returns an error and the agent explains why.

5. **Does it require multiple tools?** → Chain them.
   - "I want to return something but I don't remember my order ID" → Agent asks for email → Analyst looks up orders → Agent presents them → customer picks one → `InitiateReturn` processes it.

6. **Is it out of scope?** → Politely decline.

### Multi-turn State

The Cortex Agent API is stateless — conversation history is sent with each request. The Streamlit app manages this via `st.session_state`, passing the full message list on every turn. For the agent-object variant, Cortex threads can also be used for server-side context management.

---

## 3. System Prompt & Instructions

Instead of a single monolithic system prompt, Snowflake Cortex Agents split instructions into two scopes:

**Response instructions** (controls the agent's personality and output style):
```
You are Paige, a friendly and professional customer support representative for Bookly,
an online bookstore. Be warm, concise, and empathetic. Use the customer's name if available.
Never reveal that you are an AI or language model.
Only answer questions related to Bookly's services — politely decline anything out of scope.
Never fabricate order details, tracking numbers, prices, or dates.
If a tool returns no results, tell the customer you couldn't find matching records.
```

**Orchestration instructions** (controls tool selection and workflow):
```
For order status, tracking, delivery dates, or any question about a specific order,
use the Cortex Analyst tool to query the orders database.
For policy questions about returns, shipping, refunds, password resets, account help,
or order changes, use the Cortex Search tool to find the relevant policy.
If the customer's intent is ambiguous, ask a clarifying question before using any tool.
For return requests, follow this sequence:
  (1) Gather the order ID and reason for return from the customer.
  (2) Use the InitiateReturn custom tool with the order ID and reason.
  (3) If the return succeeds, share the RMA number and shipping instructions.
  (4) If it fails, relay the error message to the customer.
```

**Key design choices:**
- **Persona with a name ("Paige")** — consistent, personal experience.
- **Split instructions** — response tone is decoupled from routing logic, making each easier to iterate on independently.
- **Explicit return workflow** — step-by-step instructions ensure the agent gathers info first, then acts. Validation is server-side in the stored procedure, not in the prompt.
- **No-fabrication rule** — only state facts from tool results.
- **Side-effect tool** — `InitiateReturn` is a *write* operation (inserts into `RETURNS` table), making this a true agentic action, not just retrieval.

---

## 4. Hallucination & Safety Controls

| Control | How it works |
|---|---|
| **Tool-grounded answers** | Response instructions require the agent to only state facts returned by Cortex Analyst or Cortex Search. No tool result → "I couldn't find that." |
| **Cortex Analyst semantic model** | The YAML defines exact column names, types, sample values, and synonyms. This constrains SQL generation to valid queries — the model can't reference columns that don't exist. |
| **Cortex Search with citations** | Search results include source document IDs and titles, enabling traceability. The agent can cite which policy it's referencing. |
| **Orchestration guardrails** | Explicit instructions prevent the agent from answering order-specific questions without querying the database, and policy questions without consulting the search index. |
| **Scope restriction** | Response instructions limit the agent to Bookly topics. Out-of-scope requests are declined. |
| **Server-side action validation** | The `INITIATE_RETURN` stored procedure enforces business rules (order must be delivered, within 30-day window) in SQL — not in the prompt. The LLM cannot bypass these checks. Even if the agent is tricked into calling the procedure with invalid inputs, the procedure rejects them and returns an error. |
| **Built-in answer abstaining** | Cortex Agent has native support for abstaining when a question is irrelevant to the available tools. |
| **Data stays in Snowflake** | All order data and policies remain within Snowflake's security perimeter. No data is sent to third-party LLM APIs — Cortex runs models within Snowflake's infrastructure. |

**What's NOT covered (and would be needed in production):**
- Input sanitization for prompt injection attempts.
- Row-level security on the `ORDERS` table (so customers can only see their own orders).
- Audit logging of every agent interaction for compliance.
- Rate limiting on the REST API.

---

## 5. Production Readiness — Tradeoffs & Next Steps

### Tradeoffs Made to Move Quickly

| Shortcut | Risk | Production fix |
|---|---|---|
| PAT-based auth | Token rotation is manual; single-user | OAuth 2.0 flow or key-pair JWT auth; per-customer sessions |
| No row-level security | Any user can query any order | Dynamic masking policies; verify caller identity before disclosing order details |
| In-memory session state | Lost on Streamlit restart | Use Cortex threads for server-side context, or persist to Redis/DynamoDB |
| Sample data only | Can't test real edge cases | Connect to production order management system |
| No evaluation pipeline | Can't measure quality over time | Scripted test conversations with expected outputs; track intent accuracy, grounding rate |
| No human handoff | Agent handles everything or fails | Integrate with live-agent system (Zendesk, Intercom) for escalation |

### What I'd Change for Production

1. **Authentication & authorization** — OAuth flow so each customer is authenticated; row-level security on `ORDERS` so they only see their own data.
2. **Cortex threads** — Use the thread API for server-side conversation persistence instead of client-side session state.
3. **Evaluation suite** — Automated test harness that runs scripted conversations against the agent on every prompt or semantic model change. Metrics: SQL accuracy, search relevance, response grounding.
4. **Observability** — Log every request/response pair with `run_id`, tool calls, latency, and token usage. Build dashboards for resolution rate, average turns, and escalation frequency.
5. **Human handoff** — If the customer is frustrated or the agent can't resolve the issue, seamlessly transfer to a human agent with full conversation context.
6. **Semantic view migration** — Move from stage-based YAML to Snowflake's native Semantic Views for better governance, versioning, and access control.
7. **Additional custom tools** — Extend the stored procedure pattern to more actions: cancel order, update shipping address, apply promo codes. Each would be a separate procedure with its own validation logic, registered as a custom tool.
8. **Action confirmation** — Add a confirmation step before executing write operations (returns, cancellations). The agent would present what it's about to do and ask the customer to confirm before calling the procedure.
