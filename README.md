# Bookly Support Agent

A conversational AI customer support agent for **Bookly**, a fictional online bookstore. Powered by **Snowflake Cortex** (Agent API, Cortex Search, Cortex Analyst) with a **Streamlit** chat UI.

Agent: [Snowflake Cortex Agent](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents)
Tools: 
Snowflake Cortex Analyst (text-to-SQL) for structured data E.g. Orders table
Snowflake Cortex Search (Hybrid Search) for unstructured data E.g. Policies
Custom (Snowflake Stored Proc) for DML operations needed for return workflow


## Architecture

```
Streamlit Chat UI (app.py)
        │
        ▼
Cortex Agent REST API
        │
   ┌────┼────────────┐
   ▼    ▼            ▼
Cortex  Cortex    Custom Tool
Analyst Search    (Stored Proc)
(Orders)(Policies)(Returns)
   │    │            │
   ▼    ▼            ▼
ORDERS  POLICIES  INITIATE_RETURN proc
(SQL)   (search)  → validates & writes to RETURNS table
```

- **Cortex Analyst** converts natural language into SQL against the `ORDERS` table using a semantic model
- **Cortex Search** performs hybrid semantic + keyword search across the `POLICIES` table
- **Custom Tool** (`InitiateReturn`) calls a Snowflake stored procedure that validates the order, checks the 30-day return window, and creates an RMA record in the `RETURNS` table
- **Cortex Agent** orchestrates across all three tools, manages multi-turn context, and streams responses

## Setup

### 1. Snowflake infrastructure

Run `snowflake_setup.sql` in a Snowsight SQL worksheet (as `ACCOUNTADMIN`). This creates:
- Database `BOOKLY` with tables `ORDERS`, `RETURNS`, and `POLICIES`
- Stored procedure `INITIATE_RETURN` (validates order & creates RMA records)
- Cortex Search service `BOOKLY_POLICY_SEARCH`
- Stage `SEMANTIC_MODELS` for the Cortex Analyst YAML

### 2. Upload the semantic model

Upload `bookly_orders_semantic_model.yaml` to the stage:

```sql
PUT file://bookly_orders_semantic_model.yaml @BOOKLY.SUPPORT.SEMANTIC_MODELS AUTO_COMPRESS=FALSE;
```

Or use the Snowsight UI: **Data > BOOKLY > SUPPORT > Stages > SEMANTIC_MODELS > Upload**.

### 3. Create the Cortex Agent

The agent is created programmatically by Step 9 in `snowflake_setup.sql` using `CREATE AGENT`. Since the agent references the semantic model file on the stage, run steps 1–8 first, upload the YAML (step 2 above), then execute step 9.

The `CREATE AGENT` statement configures:
- **OrderLookup** — Cortex Analyst tool with the semantic model
- **PolicySearch** — Cortex Search tool pointing to `BOOKLY_POLICY_SEARCH`
- **InitiateReturn** — Custom tool calling the `INITIATE_RETURN` stored procedure
- Orchestration and response instructions
- Sample questions

### 4. Create a Programmatic Access Token (PAT)

In Snowsight: **Profile > Settings > Authentication > Programmatic access tokens > Generate new token**. Copy the token.

### 5. Install Python dependencies

Requires **Python 3.10+**.

```bash
python3.10 -m venv cust-support-venv
source cust-support-venv/bin/activate
pip install -r requirements.txt
```

### 6. Configure environment

```bash
cp .env.example .env
# Edit .env with your PAT, account URL, and agent details
```

### 7. Run the app

```bash
streamlit run app.py
```

Opens at [http://localhost:8501](http://localhost:8501).

## Try These Conversations

**Order status (Cortex Analyst generates SQL):**
> "Where is my order ORD-1042?"

**Return flow (multi-turn with clarifying question + action):**
> "I need help with my order"
> → Agent asks what kind of help
> "I want to return a book"
> → Agent asks for order ID and reason
> "ORD-1103, the book was damaged"
> → Agent calls `InitiateReturn` stored procedure → returns RMA number and shipping instructions

**Return guardrail (order not eligible):**
> "I want to return order ORD-1042"
> → Agent calls `InitiateReturn` → procedure rejects: order is "shipped", not "delivered"

**Policy questions (Cortex Search):**
> "What's your shipping policy?"
> "How do refunds work?"
> "I forgot my password"

**Out-of-scope (guardrail):**
> "Can you help me book a flight?"

## Test Data

| Order ID | Email | Status | Items |
|---|---|---|---|
| ORD-1042 | alice@example.com | Shipped | The Great Gatsby, 1984 |
| ORD-1087 | bob@example.com | Processing | Dune |
| ORD-1103 | alice@example.com | Delivered | Sapiens, Educated (x2) |

## Project Structure

```
├── app.py                              # Streamlit chat UI with streaming
├── agent.py                            # Cortex Agent API client
├── snowflake_setup.sql                 # Snowflake DDL: tables, search service, stage
├── bookly_orders_semantic_model.yaml   # Cortex Analyst semantic model for orders
├── DESIGN_DOCUMENT.md                  # Architecture & design write-up
├── requirements.txt                    # Python dependencies
└── .env.example                        # Environment variable template
```

## Design Document

See [DESIGN_DOCUMENT.md](DESIGN_DOCUMENT.md) for the full architecture overview, conversation design decisions, hallucination controls, and production readiness analysis.
