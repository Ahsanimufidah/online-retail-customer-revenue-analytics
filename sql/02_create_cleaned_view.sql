CREATE SCHEMA IF NOT EXISTS clean;

DROP VIEW IF EXISTS clean.vw_online_retail_clean;

CREATE VIEW clean.vw_online_retail_clean AS
SELECT
    invoice,
    stock_code,
    NULLIF(TRIM(description), '') AS description,
    quantity,
    invoice_date_text,

    TO_TIMESTAMP(invoice_date_text, 'MM/DD/YY HH24:MI') AS invoice_datetime,
    TO_TIMESTAMP(invoice_date_text, 'MM/DD/YY HH24:MI')::date AS invoice_date,
    DATE_TRUNC('month', TO_TIMESTAMP(invoice_date_text, 'MM/DD/YY HH24:MI'))::date AS invoice_month,

    price,
    NULLIF(TRIM(customer_id), '') AS customer_id,
    country,

    quantity * price AS line_revenue,

    CASE
        WHEN invoice ILIKE 'C%' THEN 1
        ELSE 0
    END AS is_cancelled_invoice,

    CASE
        WHEN quantity < 0 THEN 1
        ELSE 0
    END AS is_negative_quantity,

    CASE
        WHEN price <= 0 THEN 1
        ELSE 0
    END AS is_zero_or_negative_price,

    CASE
        WHEN customer_id IS NULL OR TRIM(customer_id) = '' THEN 1
        ELSE 0
    END AS is_missing_customer,

    CASE
        WHEN invoice NOT ILIKE 'C%'
             AND quantity > 0
             AND price > 0
             AND customer_id IS NOT NULL
             AND TRIM(customer_id) <> ''
        THEN 1
        ELSE 0
    END AS is_valid_sales_row

FROM raw.online_retail_ii;