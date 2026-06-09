CREATE SCHEMA IF NOT EXISTS raw;

DROP TABLE IF EXISTS raw.online_retail_ii;

CREATE TABLE raw.online_retail_ii (
    invoice TEXT,
    stock_code TEXT,
    description TEXT,
    quantity INTEGER,
    invoice_date_text TEXT,
    price NUMERIC(12, 4),
    customer_id TEXT,
    country TEXT
);