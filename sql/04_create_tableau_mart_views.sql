CREATE SCHEMA IF NOT EXISTS mart;


-- =========================================================
-- DASHBOARD 1: RFM CUSTOMER SEGMENTATION
-- =========================================================

DROP VIEW IF EXISTS mart.vw_dashboard1_rfm_segment_summary;
DROP VIEW IF EXISTS mart.vw_dashboard1_rfm_customers;

CREATE VIEW mart.vw_dashboard1_rfm_customers AS
WITH valid_sales AS (
    SELECT
        customer_id,
        invoice,
        invoice_date,
        line_revenue
    FROM clean.vw_online_retail_clean
    WHERE is_valid_sales_row = 1
),

snapshot_date AS (
    SELECT
        MAX(invoice_date) + INTERVAL '1 day' AS analysis_date
    FROM valid_sales
),

customer_metrics AS (
    SELECT
        vs.customer_id,
        MAX(vs.invoice_date) AS last_purchase_date,
        COUNT(DISTINCT vs.invoice) AS frequency,
        SUM(vs.line_revenue) AS monetary,
        (SELECT analysis_date FROM snapshot_date)::date - MAX(vs.invoice_date) AS recency_days
    FROM valid_sales vs
    GROUP BY vs.customer_id
),

rfm_scores AS (
    SELECT
        customer_id,
        last_purchase_date,
        recency_days,
        frequency,
        monetary,

        NTILE(5) OVER (ORDER BY recency_days DESC) AS recency_score,
        NTILE(5) OVER (ORDER BY frequency ASC) AS frequency_score,
        NTILE(5) OVER (ORDER BY monetary ASC) AS monetary_score
    FROM customer_metrics
),

rfm_final AS (
    SELECT
        customer_id,
        last_purchase_date,
        recency_days,
        frequency,
        monetary,
        recency_score,
        frequency_score,
        monetary_score,
        CONCAT(recency_score, frequency_score, monetary_score) AS rfm_score,

        CASE
            WHEN recency_score >= 4 AND frequency_score >= 4 AND monetary_score >= 4
                THEN 'Champions'
            WHEN recency_score >= 3 AND frequency_score >= 4 AND monetary_score >= 3
                THEN 'Loyal Customers'
            WHEN recency_score >= 4 AND frequency_score BETWEEN 2 AND 3
                THEN 'Potential Loyalists'
            WHEN recency_score = 5 AND frequency_score = 1
                THEN 'New Customers'
            WHEN recency_score <= 2 AND frequency_score >= 4 AND monetary_score >= 4
                THEN 'Cannot Lose Them'
            WHEN recency_score <= 2 AND frequency_score >= 3
                THEN 'At Risk'
            WHEN recency_score = 1 AND frequency_score <= 2
                THEN 'Lost'
            WHEN recency_score <= 2 AND frequency_score <= 2
                THEN 'Hibernating'
            ELSE 'Needs Attention'
        END AS customer_segment
    FROM rfm_scores
)

SELECT *
FROM rfm_final;


CREATE VIEW mart.vw_dashboard1_rfm_segment_summary AS
SELECT
    customer_segment,
    COUNT(DISTINCT customer_id) AS customer_count,
    SUM(monetary) AS total_revenue,
    AVG(recency_days) AS avg_recency_days,
    AVG(frequency) AS avg_frequency,
    AVG(monetary) AS avg_monetary_value
FROM mart.vw_dashboard1_rfm_customers
GROUP BY customer_segment;



-- =========================================================
-- DASHBOARD 2: COHORT RETENTION ANALYSIS
-- =========================================================

DROP VIEW IF EXISTS mart.vw_dashboard2_retention_curve;
DROP VIEW IF EXISTS mart.vw_dashboard2_cohort_retention;

CREATE VIEW mart.vw_dashboard2_cohort_retention AS
WITH valid_sales AS (
    SELECT DISTINCT
        customer_id,
        invoice_month
    FROM clean.vw_online_retail_clean
    WHERE is_valid_sales_row = 1
),

customer_cohort AS (
    SELECT
        customer_id,
        MIN(invoice_month) AS cohort_month
    FROM valid_sales
    GROUP BY customer_id
),

customer_month_activity AS (
    SELECT
        vs.customer_id,
        cc.cohort_month,
        vs.invoice_month AS purchase_month,

        (
            (EXTRACT(YEAR FROM vs.invoice_month)::int - EXTRACT(YEAR FROM cc.cohort_month)::int) * 12
            + (EXTRACT(MONTH FROM vs.invoice_month)::int - EXTRACT(MONTH FROM cc.cohort_month)::int)
            + 1
        ) AS cohort_month_number

    FROM valid_sales vs
    JOIN customer_cohort cc
        ON vs.customer_id = cc.customer_id
),

cohort_size AS (
    SELECT
        cohort_month,
        COUNT(DISTINCT customer_id) AS cohort_customers
    FROM customer_cohort
    GROUP BY cohort_month
),

retention AS (
    SELECT
        cohort_month,
        cohort_month_number,
        COUNT(DISTINCT customer_id) AS retained_customers
    FROM customer_month_activity
    GROUP BY
        cohort_month,
        cohort_month_number
)

SELECT
    r.cohort_month,
    TO_CHAR(r.cohort_month, 'YYYY-MM') AS cohort_month_label,
    r.cohort_month_number,
    cs.cohort_customers,
    r.retained_customers,
    ROUND((r.retained_customers::numeric / cs.cohort_customers) * 100, 2) AS retention_rate_pct
FROM retention r
JOIN cohort_size cs
    ON r.cohort_month = cs.cohort_month;


CREATE VIEW mart.vw_dashboard2_retention_curve AS
SELECT
    cohort_month_number,
    ROUND(AVG(retention_rate_pct), 2) AS avg_retention_rate_pct,
    SUM(retained_customers) AS total_retained_customers,
    SUM(cohort_customers) AS total_cohort_customers
FROM mart.vw_dashboard2_cohort_retention
GROUP BY cohort_month_number;



-- =========================================================
-- DASHBOARD 3: PRODUCT AND REVENUE ANALYSIS
-- =========================================================

DROP VIEW IF EXISTS mart.vw_dashboard3_kpi_summary;
DROP VIEW IF EXISTS mart.vw_dashboard3_product_return_risk_top20;
DROP VIEW IF EXISTS mart.vw_dashboard3_product_pareto_top20;
DROP VIEW IF EXISTS mart.vw_dashboard3_product_pairs;
DROP VIEW IF EXISTS mart.vw_dashboard3_monthly_revenue_returns;
DROP VIEW IF EXISTS mart.vw_dashboard3_product_performance;


CREATE VIEW mart.vw_dashboard3_product_performance AS
WITH sales AS (
    SELECT
        stock_code,
        description,
        SUM(quantity) AS sales_quantity,
        SUM(line_revenue) AS sales_revenue,
        COUNT(DISTINCT invoice) AS sales_orders
    FROM clean.vw_online_retail_clean
    WHERE is_valid_sales_row = 1
    GROUP BY stock_code, description
),

returns AS (
    SELECT
        stock_code,
        description,
        SUM(ABS(quantity)) AS returned_quantity,
        ABS(SUM(line_revenue)) AS returned_value,
        COUNT(DISTINCT invoice) AS return_orders
    FROM clean.vw_online_retail_clean
    WHERE quantity < 0
       OR is_cancelled_invoice = 1
    GROUP BY stock_code, description
),

combined AS (
    SELECT
        s.stock_code,
        s.description,
        s.sales_quantity,
        s.sales_revenue,
        s.sales_orders,
        COALESCE(r.returned_quantity, 0) AS returned_quantity,
        COALESCE(r.returned_value, 0) AS returned_value,
        COALESCE(r.return_orders, 0) AS return_orders,

        ROUND(
            COALESCE(r.returned_quantity, 0)::numeric
            / NULLIF(s.sales_quantity + COALESCE(r.returned_quantity, 0), 0) * 100,
            2
        ) AS return_share_pct
    FROM sales s
    LEFT JOIN returns r
        ON s.stock_code = r.stock_code
)

SELECT *
FROM combined;


CREATE VIEW mart.vw_dashboard3_monthly_revenue_returns AS
SELECT
    invoice_month,
    TO_CHAR(invoice_month, 'YYYY-MM') AS invoice_month_label,

    SUM(CASE WHEN is_valid_sales_row = 1 THEN line_revenue ELSE 0 END) AS sales_revenue,
    COUNT(DISTINCT CASE WHEN is_valid_sales_row = 1 THEN invoice END) AS sales_orders,

    ABS(SUM(CASE WHEN quantity < 0 OR is_cancelled_invoice = 1 THEN line_revenue ELSE 0 END)) AS returned_value,
    COUNT(DISTINCT CASE WHEN quantity < 0 OR is_cancelled_invoice = 1 THEN invoice END) AS return_orders
FROM clean.vw_online_retail_clean
GROUP BY invoice_month;


CREATE VIEW mart.vw_dashboard3_product_pairs AS
WITH invoice_products AS (
    SELECT DISTINCT
        invoice,
        stock_code,
        description
    FROM clean.vw_online_retail_clean
    WHERE is_valid_sales_row = 1
),

product_pairs AS (
    SELECT
        p1.stock_code AS product_1_code,
        p1.description AS product_1_description,
        p2.stock_code AS product_2_code,
        p2.description AS product_2_description,
        COUNT(DISTINCT p1.invoice) AS times_bought_together
    FROM invoice_products p1
    JOIN invoice_products p2
        ON p1.invoice = p2.invoice
       AND p1.stock_code < p2.stock_code
    GROUP BY
        p1.stock_code,
        p1.description,
        p2.stock_code,
        p2.description
),

ranked_pairs AS (
    SELECT
        *,
        RANK() OVER (ORDER BY times_bought_together DESC) AS pair_rank
    FROM product_pairs
)

SELECT *
FROM ranked_pairs
WHERE pair_rank <= 100;


CREATE VIEW mart.vw_dashboard3_product_pareto_top20 AS
WITH product_sales AS (
    SELECT
        stock_code,
        MAX(description) AS product_description,
        SUM(quantity) AS sales_quantity,
        SUM(line_revenue) AS sales_revenue,
        COUNT(DISTINCT invoice) AS sales_orders
    FROM clean.vw_online_retail_clean
    WHERE is_valid_sales_row = 1
      AND stock_code IS NOT NULL
    GROUP BY stock_code
),

product_returns AS (
    SELECT
        stock_code,
        SUM(ABS(quantity)) AS returned_quantity,
        COUNT(DISTINCT invoice) AS return_orders
    FROM clean.vw_online_retail_clean
    WHERE quantity < 0
       OR is_cancelled_invoice = 1
    GROUP BY stock_code
),

combined AS (
    SELECT
        ps.stock_code,
        ps.product_description,
        ps.sales_quantity,
        ps.sales_revenue,
        ps.sales_orders,
        COALESCE(pr.returned_quantity, 0) AS returned_quantity,
        COALESCE(pr.return_orders, 0) AS return_orders,
        ROUND(
            COALESCE(pr.returned_quantity, 0)::numeric
            / NULLIF(ps.sales_quantity + COALESCE(pr.returned_quantity, 0), 0) * 100,
            2
        ) AS return_share_pct
    FROM product_sales ps
    LEFT JOIN product_returns pr
        ON ps.stock_code = pr.stock_code
),

ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            ORDER BY sales_revenue DESC, stock_code
        ) AS pareto_rank,
        SUM(sales_revenue) OVER () AS total_revenue_all_products,
        SUM(sales_revenue) OVER (
            ORDER BY sales_revenue DESC, stock_code
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_revenue
    FROM combined
    WHERE sales_revenue > 0
)

SELECT
    pareto_rank,
    LPAD(pareto_rank::text, 3, '0')
        || '. '
        || stock_code
        || ' - '
        || LEFT(COALESCE(product_description, 'Unknown product'), 35) AS product_label,
    stock_code,
    product_description,
    sales_revenue,
    sales_quantity,
    sales_orders,
    returned_quantity,
    return_orders,
    return_share_pct,
    ROUND((sales_revenue / total_revenue_all_products) * 100, 2) AS revenue_share_pct,
    ROUND((cumulative_revenue / total_revenue_all_products) * 100, 2) AS cumulative_revenue_pct
FROM ranked
WHERE pareto_rank <= 20
ORDER BY pareto_rank;


CREATE VIEW mart.vw_dashboard3_product_return_risk_top20 AS
WITH product_sales AS (
    SELECT
        stock_code,
        MAX(description) AS product_description,
        SUM(quantity) AS sales_quantity,
        SUM(line_revenue) AS sales_revenue,
        COUNT(DISTINCT invoice) AS sales_orders
    FROM clean.vw_online_retail_clean
    WHERE is_valid_sales_row = 1
      AND stock_code IS NOT NULL
    GROUP BY stock_code
),

product_returns AS (
    SELECT
        stock_code,
        SUM(ABS(quantity)) AS returned_quantity,
        ABS(SUM(line_revenue)) AS returned_value,
        COUNT(DISTINCT invoice) AS return_orders
    FROM clean.vw_online_retail_clean
    WHERE quantity < 0
       OR is_cancelled_invoice = 1
    GROUP BY stock_code
),

combined AS (
    SELECT
        ps.stock_code,
        ps.product_description,
        ps.sales_quantity,
        ps.sales_revenue,
        ps.sales_orders,
        COALESCE(pr.returned_quantity, 0) AS returned_quantity,
        COALESCE(pr.returned_value, 0) AS returned_value,
        COALESCE(pr.return_orders, 0) AS return_orders,

        ROUND(
            COALESCE(pr.returned_quantity, 0)::numeric
            / NULLIF(ps.sales_quantity + COALESCE(pr.returned_quantity, 0), 0) * 100,
            2
        ) AS return_share_pct
    FROM product_sales ps
    LEFT JOIN product_returns pr
        ON ps.stock_code = pr.stock_code
),

ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            ORDER BY return_share_pct DESC, returned_quantity DESC, sales_revenue DESC
        ) AS return_risk_rank
    FROM combined
    WHERE sales_orders >= 20
      AND sales_quantity >= 50
      AND sales_revenue > 500
      AND returned_quantity > 0
)

SELECT
    return_risk_rank,
    LPAD(return_risk_rank::text, 3, '0')
        || '. '
        || stock_code
        || ' - '
        || LEFT(COALESCE(product_description, 'Unknown product'), 35) AS product_label,
    stock_code,
    product_description,
    sales_quantity,
    sales_revenue,
    sales_orders,
    returned_quantity,
    returned_value,
    return_orders,
    return_share_pct
FROM ranked
WHERE return_risk_rank <= 20
ORDER BY return_risk_rank;


CREATE VIEW mart.vw_dashboard3_kpi_summary AS
WITH product_sales AS (
    SELECT
        stock_code,
        SUM(quantity) AS sales_quantity,
        SUM(line_revenue) AS sales_revenue,
        COUNT(DISTINCT invoice) AS sales_orders
    FROM clean.vw_online_retail_clean
    WHERE is_valid_sales_row = 1
      AND stock_code IS NOT NULL
    GROUP BY stock_code
),

product_returns AS (
    SELECT
        stock_code,
        SUM(ABS(quantity)) AS returned_quantity,
        ABS(SUM(line_revenue)) AS returned_value,
        COUNT(DISTINCT invoice) AS return_orders
    FROM clean.vw_online_retail_clean
    WHERE quantity < 0
       OR is_cancelled_invoice = 1
    GROUP BY stock_code
),

combined AS (
    SELECT
        ps.stock_code,
        ps.sales_quantity,
        ps.sales_revenue,
        ps.sales_orders,
        COALESCE(pr.returned_quantity, 0) AS returned_quantity,
        COALESCE(pr.returned_value, 0) AS returned_value,
        COALESCE(pr.return_orders, 0) AS return_orders
    FROM product_sales ps
    LEFT JOIN product_returns pr
        ON ps.stock_code = pr.stock_code
),

ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY sales_revenue DESC, stock_code) AS revenue_rank,
        SUM(sales_revenue) OVER () AS total_revenue_all_products,
        SUM(sales_revenue) OVER (
            ORDER BY sales_revenue DESC, stock_code
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_revenue
    FROM combined
    WHERE sales_revenue > 0
),

products_to_80 AS (
    SELECT
        MIN(revenue_rank) AS products_needed_for_80pct_revenue
    FROM ranked
    WHERE cumulative_revenue / total_revenue_all_products >= 0.80
),

top20_share AS (
    SELECT
        ROUND(
            SUM(CASE WHEN revenue_rank <= 20 THEN sales_revenue ELSE 0 END)
            / MAX(total_revenue_all_products) * 100,
            2
        ) AS top20_revenue_share_pct
    FROM ranked
),

country_summary AS (
    SELECT
        COUNT(DISTINCT country) AS total_countries
    FROM clean.vw_online_retail_clean
    WHERE is_valid_sales_row = 1
)

SELECT
    COUNT(DISTINCT c.stock_code) AS active_products,
    ROUND(SUM(c.sales_revenue), 2) AS total_revenue,
    cs.total_countries,
    ROUND(
        SUM(c.returned_quantity)::numeric
        / NULLIF(SUM(c.sales_quantity + c.returned_quantity), 0) * 100,
        2
    ) AS weighted_return_share_pct,
    p80.products_needed_for_80pct_revenue,
    t20.top20_revenue_share_pct
FROM combined c
CROSS JOIN country_summary cs
CROSS JOIN products_to_80 p80
CROSS JOIN top20_share t20
WHERE c.sales_revenue > 0
GROUP BY
    cs.total_countries,
    p80.products_needed_for_80pct_revenue,
    t20.top20_revenue_share_pct;