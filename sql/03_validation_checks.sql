-- 1. Check total raw rows
SELECT
    COUNT(*) AS total_raw_rows
FROM raw.online_retail_ii;


-- 2. Check cleaned view row status
SELECT
    COUNT(*) AS total_rows,
    SUM(is_valid_sales_row) AS valid_sales_rows,
    SUM(is_missing_customer) AS missing_customer_rows,
    SUM(is_cancelled_invoice) AS cancelled_invoice_rows,
    SUM(is_negative_quantity) AS negative_quantity_rows,
    SUM(is_zero_or_negative_price) AS zero_or_negative_price_rows
FROM clean.vw_online_retail_clean;


-- 3. Check date range
SELECT
    MIN(invoice_date) AS first_invoice_date,
    MAX(invoice_date) AS last_invoice_date
FROM clean.vw_online_retail_clean;


-- 4. Check valid customer and invoice counts
SELECT
    COUNT(DISTINCT customer_id) AS unique_customers,
    COUNT(DISTINCT invoice) AS unique_invoices,
    COUNT(DISTINCT stock_code) AS unique_products,
    COUNT(DISTINCT country) AS unique_countries
FROM clean.vw_online_retail_clean
WHERE is_valid_sales_row = 1;


-- 5. Check revenue by country
SELECT
    country,
    ROUND(SUM(line_revenue), 2) AS total_revenue,
    COUNT(DISTINCT invoice) AS total_orders
FROM clean.vw_online_retail_clean
WHERE is_valid_sales_row = 1
GROUP BY country
ORDER BY total_revenue DESC;