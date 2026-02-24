"""
Streamlit chat UI for the Bookly customer support agent.
Powered by Snowflake Cortex Agent API with streaming responses.

Run with: streamlit run app.py
"""

import streamlit as st
from agent import CortexAgent

GREETING = (
    "Hi there! I'm Paige from Bookly. "
    "I can help you with order status, returns, shipping questions, and more. "
    "How can I help you today?"
)

SAMPLE_QUERIES = [
    "Where's my order ORD-1042?",
    "I want to return a book",
    "What's your shipping policy?",
    "I need help with my account",
]

# ── Page config ──────────────────────────────────────────────────────────────

st.set_page_config(
    page_title="Bookly Support",
    page_icon="📚",
    layout="centered",
)

# ── Custom styling ───────────────────────────────────────────────────────────

st.markdown(
    """
    <style>
    @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap');

    .stApp {
        font-family: 'Inter', sans-serif;
    }

    header[data-testid="stHeader"] {
        background: #6b4c3b;
    }

    .block-container {
        max-width: 700px;
        padding-top: 1rem;
    }

    [data-testid="stChatMessage"] {
        border-radius: 12px;
        margin-bottom: 4px;
    }

    .stChatInput > div {
        border-radius: 24px !important;
    }

    div[data-testid="stStatusWidget"] {
        display: none;
    }
    </style>
    """,
    unsafe_allow_html=True,
)

# ── Header ───────────────────────────────────────────────────────────────────

st.markdown(
    """
    <div style="
        background: #6b4c3b;
        color: white;
        padding: 18px 24px;
        border-radius: 12px;
        margin-bottom: 16px;
        display: flex;
        align-items: center;
        gap: 14px;
    ">
        <div style="
            width: 44px; height: 44px;
            background: #d4a574;
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 22px;
            flex-shrink: 0;
        ">📚</div>
        <div>
            <div style="font-size: 17px; font-weight: 600;">Bookly Support</div>
            <div style="font-size: 12px; opacity: 0.85;">Paige is here to help</div>
        </div>
    </div>
    """,
    unsafe_allow_html=True,
)

# ── Session state init ───────────────────────────────────────────────────────

if "agent" not in st.session_state:
    st.session_state.agent = CortexAgent()
    st.session_state.chat_history = [{"role": "assistant", "content": GREETING}]
    st.session_state.samples_used = False

# ── Render chat history ──────────────────────────────────────────────────────

for msg in st.session_state.chat_history:
    avatar = "📖" if msg["role"] == "assistant" else "👤"
    with st.chat_message(msg["role"], avatar=avatar):
        st.markdown(msg["content"])


# ── Handle user input ────────────────────────────────────────────────────────

def handle_input(user_text: str):
    """Process a user message and stream the agent's response."""
    st.session_state.chat_history.append({"role": "user", "content": user_text})
    with st.chat_message("user", avatar="👤"):
        st.markdown(user_text)

    with st.chat_message("assistant", avatar="📖"):
        status_placeholder = st.empty()
        response_placeholder = st.empty()
        full_text = ""

        try:
            for chunk in st.session_state.agent.chat_stream(user_text):
                if chunk.event_type == "text_delta":
                    full_text += chunk.text
                    response_placeholder.markdown(full_text + "▌")

                elif chunk.event_type == "status":
                    status_placeholder.caption(f"⏳ {chunk.status}")

                elif chunk.event_type == "tool_use":
                    tool_name = chunk.data.get("name", "tool")
                    st.expander(f"🔧 Using: {tool_name}").json(chunk.data)

                elif chunk.event_type == "error":
                    full_text = f"I'm sorry, I ran into an issue: {chunk.text}"

                elif chunk.event_type == "done":
                    status_placeholder.empty()

        except Exception as e:
            full_text = f"**Error:** {type(e).__name__}: {e}"

        if not full_text:
            full_text = "I'm sorry, I wasn't able to generate a response."

        response_placeholder.markdown(full_text)

    st.session_state.chat_history.append({"role": "assistant", "content": full_text})
    st.session_state.samples_used = True


# ── Sample query buttons ─────────────────────────────────────────────────────

if not st.session_state.samples_used:
    cols = st.columns(2)
    for i, query in enumerate(SAMPLE_QUERIES):
        if cols[i % 2].button(query, key=f"sample_{i}", use_container_width=True):
            handle_input(query)
            st.rerun()

# ── Chat input ───────────────────────────────────────────────────────────────

if user_input := st.chat_input("Type a message..."):
    handle_input(user_input)
    st.rerun()
