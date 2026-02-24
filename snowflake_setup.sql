-- =============================================================================
-- Bookly Customer Support Agent — Snowflake Setup
-- =============================================================================
-- Run this script in a Snowsight SQL worksheet (as ACCOUNTADMIN) to create
-- the database, tables, Cortex Search service, semantic model stage,
-- and the Cortex Agent.
-- =============================================================================

-- 1. Role & permissions -------------------------------------------------------
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE ROLE bookly_support_role;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE bookly_support_role;

SET my_user = CURRENT_USER();
GRANT ROLE bookly_support_role TO USER IDENTIFIER($my_user);

-- 2. Database, schema, warehouse ----------------------------------------------
CREATE OR REPLACE DATABASE bookly;
CREATE OR REPLACE SCHEMA bookly.support;

GRANT USAGE ON DATABASE bookly TO ROLE bookly_support_role;
GRANT USAGE ON SCHEMA bookly.support TO ROLE bookly_support_role;

GRANT CREATE AGENT ON SCHEMA bookly.support TO ROLE bookly_support_role;

CREATE OR REPLACE WAREHOUSE bookly_wh
WITH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = FALSE;

GRANT USAGE, OPERATE ON WAREHOUSE bookly_wh TO ROLE bookly_support_role;

-- 3. Orders table (structured data — queried via Cortex Analyst) --------------
--    Each row is one line item. Orders with multiple books share the same ORDER_ID.
USE DATABASE bookly;
USE SCHEMA support;
USE WAREHOUSE bookly_wh;

CREATE OR REPLACE TABLE orders (
    order_id        VARCHAR NOT NULL,
    customer_email  VARCHAR NOT NULL,
    customer_name   VARCHAR,
    item_title      VARCHAR NOT NULL,
    item_qty        INT,
    item_price      FLOAT,
    order_status    VARCHAR NOT NULL,
    tracking_number VARCHAR,
    carrier         VARCHAR,
    order_date      DATE,
    estimated_delivery DATE,
    delivered_date  DATE,
    order_total     FLOAT
);

INSERT INTO orders VALUES
('ORD-1042', 'alice@example.com', 'Alice',   'The Great Gatsby', 1, 12.99, 'shipped',     '1Z999AA10123456784',       'UPS',  DATEADD(DAY, -5, CURRENT_DATE()), DATEADD(DAY, 2, CURRENT_DATE()),  NULL, 22.98),
('ORD-1042', 'alice@example.com', 'Alice',   '1984',             1,  9.99, 'shipped',     '1Z999AA10123456784',       'UPS',  DATEADD(DAY, -5, CURRENT_DATE()), DATEADD(DAY, 2, CURRENT_DATE()),  NULL, 22.98),
('ORD-1087', 'bob@example.com',   'Bob',     'Dune',             1, 15.99, 'processing',  NULL,                        NULL,   DATEADD(DAY, -1, CURRENT_DATE()), DATEADD(DAY, 5, CURRENT_DATE()),  NULL, 15.99),
('ORD-1103', 'alice@example.com', 'Alice',   'Sapiens',          1, 18.50, 'delivered',   '9400111899223100001',       'USPS', DATEADD(DAY,-12, CURRENT_DATE()), DATEADD(DAY,-5, CURRENT_DATE()),  DATEADD(DAY, -4, CURRENT_DATE()), 48.48),
('ORD-1103', 'alice@example.com', 'Alice',   'Educated',         2, 14.99, 'delivered',   '9400111899223100001',       'USPS', DATEADD(DAY,-12, CURRENT_DATE()), DATEADD(DAY,-5, CURRENT_DATE()),  DATEADD(DAY, -4, CURRENT_DATE()), 48.48);

GRANT SELECT ON TABLE orders TO ROLE bookly_support_role;
GRANT SELECT ON FUTURE TABLES IN SCHEMA bookly.support TO ROLE bookly_support_role;

-- 4. Policies table (queried via Cortex Search) -------------------------------
CREATE OR REPLACE TABLE policies (
    policy_id    VARCHAR,
    topic        VARCHAR,
    policy_title VARCHAR,
    policy_text  TEXT
);

INSERT INTO policies VALUES
('POL-001', 'returns', 'Return Policy',
 'Bookly accepts returns within 30 days of delivery. Books must be in original condition — unmarked, undamaged, and with any shrink wrap intact. Digital purchases (e-books, audiobooks) are non-refundable once downloaded. To start a return, customers must provide their order ID and the reason for the return.'),

('POL-002', 'shipping', 'Shipping Policy',
 'Standard shipping takes 5–7 business days and costs $4.99, but is free on orders over $35. Express shipping takes 2–3 business days and costs $12.99. We currently ship within the continental United States only.'),

('POL-003', 'refunds', 'Refund Policy',
 'Refunds are processed within 5–7 business days after we receive the returned item. Refunds are issued to the original payment method. Shipping costs are non-refundable unless the return is due to a Bookly error.'),

('POL-004', 'password_reset', 'Password Reset',
 'Customers can reset their password by clicking Forgot Password on the login page. A reset link is sent to the email address on file and expires after 24 hours. If the customer does not receive the email, they should check spam/junk folders or contact support to verify the email on their account.'),

('POL-005', 'order_changes', 'Order Modification & Cancellation',
 'Orders can be modified or cancelled only while in processing status. Once an order is shipped or delivered, it cannot be cancelled — the customer should initiate a return instead.'),

('POL-006', 'account', 'Account Management',
 'Customers can update their email address, shipping address, and payment methods from the My Account page. For security reasons, email changes require verification via the original email. If a customer is locked out of their account, they should use the password reset flow or contact support.');

GRANT SELECT ON TABLE policies TO ROLE bookly_support_role;

-- 5. Returns table & stored procedure (custom tool for Cortex Agent) ----------
--    Populated by the InitiateReturn stored procedure.
CREATE OR REPLACE TABLE returns (
    rma_number      VARCHAR NOT NULL,
    order_id        VARCHAR NOT NULL,
    customer_email  VARCHAR NOT NULL,
    reason          VARCHAR,
    status          VARCHAR NOT NULL,
    created_at      TIMESTAMP_NTZ NOT NULL,
    instructions    TEXT
);

GRANT SELECT, INSERT ON TABLE returns TO ROLE bookly_support_role;

CREATE OR REPLACE PROCEDURE initiate_return(p_order_id VARCHAR, p_reason VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_order_status   VARCHAR;
    v_customer_email VARCHAR;
    v_delivered_date DATE;
    v_days_since     INT;
    v_rma_number     VARCHAR;
    v_instructions   VARCHAR;
    v_order_exists   BOOLEAN DEFAULT FALSE;
BEGIN
    -- Check if order exists and get its details (take first row for multi-item orders)
    SELECT TRUE, order_status, customer_email, delivered_date
      INTO v_order_exists, v_order_status, v_customer_email, v_delivered_date
      FROM bookly.support.orders
     WHERE order_id = :p_order_id
     LIMIT 1;

    IF (NOT v_order_exists) THEN
        RETURN OBJECT_CONSTRUCT(
            'success', FALSE,
            'error', 'Order not found. Please double-check the order ID (format: ORD-XXXX).'
        );
    END IF;

    -- Only delivered orders can be returned
    IF (v_order_status != 'delivered') THEN
        RETURN OBJECT_CONSTRUCT(
            'success', FALSE,
            'error', 'Order ' || :p_order_id || ' is currently "' || v_order_status ||
                     '". Returns can only be initiated for delivered orders.'
        );
    END IF;

    -- Check 30-day return window
    IF (v_delivered_date IS NOT NULL) THEN
        v_days_since := DATEDIFF(DAY, v_delivered_date, CURRENT_DATE());
        IF (v_days_since > 30) THEN
            RETURN OBJECT_CONSTRUCT(
                'success', FALSE,
                'error', 'The 30-day return window has closed for this order (delivered ' ||
                         v_days_since || ' days ago).'
            );
        END IF;
    END IF;

    -- Generate RMA number and create the return record
    v_rma_number := 'RMA-' || REPLACE(:p_order_id, 'ORD-', '');
    v_instructions := 'Return approved. Your RMA number is ' || v_rma_number ||
        '. Please ship the book(s) to: Bookly Returns Center, 123 Book Lane, Portland, OR 97201. ' ||
        'Include the RMA number on the outside of the package. ' ||
        'Once we receive and inspect the item, your refund will be processed within 5-7 business days.';

    INSERT INTO bookly.support.returns (rma_number, order_id, customer_email, reason, status, created_at, instructions)
    VALUES (:v_rma_number, :p_order_id, :v_customer_email, :p_reason, 'pending', CURRENT_TIMESTAMP(), :v_instructions);

    RETURN OBJECT_CONSTRUCT(
        'success', TRUE,
        'rma_number', v_rma_number,
        'instructions', v_instructions
    );
END;
$$;

GRANT USAGE ON PROCEDURE initiate_return(VARCHAR, VARCHAR) TO ROLE bookly_support_role;

-- 6. Cortex Search service on policies -----------------------------------------
ALTER TABLE policies SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE CORTEX SEARCH SERVICE bookly_policy_search
    ON policy_text
    ATTRIBUTES topic, policy_title
    WAREHOUSE = bookly_wh
    TARGET_LAG = '1 hour'
AS (
    SELECT
        policy_id,
        topic,
        policy_title,
        policy_text
    FROM policies
);

GRANT USAGE ON CORTEX SEARCH SERVICE bookly_policy_search TO ROLE bookly_support_role;

-- 7. Stage for semantic model YAML --------------------------------------------
CREATE OR REPLACE STAGE semantic_models DIRECTORY = (ENABLE = TRUE);
GRANT READ ON STAGE semantic_models TO ROLE bookly_support_role;

-- Upload bookly_orders_semantic_model.yaml to this stage:
--   PUT file://bookly_orders_semantic_model.yaml @bookly.support.semantic_models;
-- Or use the Snowsight UI: Data > Databases > BOOKLY > SUPPORT > Stages > SEMANTIC_MODELS > Upload

-- 8. Enable cross-region inference (required for claude models) ---------------
-- Uncomment the line below if needed for your account/region:
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'AWS_US';

-- 9. Create the Cortex Agent ---------------------------------------------------
-- NOTE: Run this AFTER uploading bookly_orders_semantic_model.yaml to the stage.
--   PUT file://bookly_orders_semantic_model.yaml @bookly.support.semantic_models AUTO_COMPRESS=FALSE;

USE ROLE bookly_support_role;
USE WAREHOUSE bookly_wh;

CREATE OR REPLACE AGENT bookly.support.bookly_support_agent
    COMMENT = 'Bookly online bookstore customer support agent'
    PROFILE = '{"display_name": "Bookly Support", "avatar": "book-icon.png", "color": "brown"}'
    FROM SPECIFICATION
$$
models:
  orchestration: auto

orchestration:
  budget:
    seconds: 30
    tokens: 16000

instructions:
  response: >
    You are Paige, a friendly and professional customer support representative
    for Bookly, an online bookstore. Be warm, concise, and empathetic. Use the
    customer's name if available. Never reveal that you are an AI or language
    model. Only answer questions related to Bookly's services — politely decline
    anything out of scope. Never fabricate order details, tracking numbers,
    prices, or dates. If a tool returns no results, tell the customer you
    couldn't find matching records.
  orchestration: >
    For order status, tracking, delivery dates, or any question about a specific
    order, use the OrderLookup tool to query the orders database.
    For policy questions about returns, shipping, refunds, password resets,
    account help, or order changes, use the PolicySearch tool to find the
    relevant policy.
    If the customer's intent is ambiguous, ask a clarifying question before
    using any tool.
    For return requests, follow this sequence:
    (1) Gather the order ID and reason for return from the customer — do not
    proceed without both.
    (2) Use the InitiateReturn custom tool with the order ID and reason. The
    procedure validates the order status and return window automatically.
    (3) If the return succeeds, share the RMA number and shipping instructions
    from the result.
    (4) If it fails, relay the error message to the customer.
  sample_questions:
    - question: "Where is my order ORD-1042?"
    - question: "I want to return a book"
    - question: "What is your shipping policy?"
    - question: "I forgot my password"

tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: OrderLookup
      description: >
        Queries the Bookly orders database for order status, tracking, items,
        delivery dates, and totals. Use for any question about a specific order
        or customer's orders.
  - tool_spec:
      type: cortex_search
      name: PolicySearch
      description: >
        Searches Bookly's policy documents for information about returns,
        shipping, refunds, password resets, order changes, and account
        management.
  - tool_spec:
      type: generic
      name: InitiateReturn
      description: >
        Processes a return/refund request for a customer order. Validates that
        the order is delivered and within the 30-day return window, then creates
        an RMA record and returns shipping instructions. Requires both the
        order ID (e.g. ORD-1103) and the reason for return.
      input_schema:
        type: object
        properties:
          P_ORDER_ID:
            type: string
            description: "The order ID to return, e.g. ORD-1103"
          P_REASON:
            type: string
            description: "Customer's reason for the return"
        required:
          - P_ORDER_ID
          - P_REASON

tool_resources:
  OrderLookup:
    semantic_model_file: "@BOOKLY.SUPPORT.SEMANTIC_MODELS/bookly_orders_semantic_model.yaml"
    execution_environment:
      type: warehouse
      warehouse: BOOKLY_WH
  PolicySearch:
    name: "BOOKLY.SUPPORT.BOOKLY_POLICY_SEARCH"
    max_results: 3
    title_column: POLICY_TITLE
    id_column: POLICY_ID
  InitiateReturn:
    type: function
    execution_environment:
      type: warehouse
      warehouse: BOOKLY_WH
    identifier: "BOOKLY.SUPPORT.INITIATE_RETURN"
$$;

-- Grant access to the agent
USE ROLE ACCOUNTADMIN;
GRANT USAGE ON AGENT bookly.support.bookly_support_agent TO ROLE bookly_support_role;

-- =============================================================================
-- NEXT STEPS:
-- 1. Upload bookly_orders_semantic_model.yaml to the stage:
--      PUT file://bookly_orders_semantic_model.yaml @bookly.support.semantic_models AUTO_COMPRESS=FALSE;
-- 2. Re-run step 9 (CREATE AGENT) after the upload completes
-- 3. Create a Programmatic Access Token (PAT) for API authentication
-- 4. Configure .env and run: streamlit run app.py
-- =============================================================================
