--  **********************************BI VIEWS************************************************
CREATE OR REPLACE VIEW bi_dim_product AS
SELECT
  p.product_id,
  COALESCE(t.product_category_name_english, p.product_category_name) AS category,
  p.product_weight_g,
  p.product_length_cm,
  p.product_height_cm,
  p.product_width_cm,
  (p.product_length_cm * p.product_height_cm * p.product_width_cm) AS volume_cm3
FROM olist_products_dataset p
LEFT JOIN product_category_name_translation t
  ON t.product_category_name = p.product_category_name;


CREATE OR REPLACE VIEW bi_fact_review_latest AS
SELECT DISTINCT ON (r.order_id)
  r.order_id,
  r.review_score,
  r.review_creation_date,
  r.review_answer_timestamp
FROM olist_order_reviews_dataset r
ORDER BY r.order_id, r.review_creation_date DESC NULLS LAST;


CREATE OR REPLACE VIEW bi_fact_order AS
SELECT
  o.order_id,
  o.customer_id,
  o.order_status,
  o.order_purchase_timestamp::date AS purchase_date,
  date_trunc('month', o.order_purchase_timestamp)::date AS purchase_month,
  o.order_delivered_customer_date::date AS delivered_date,
  o.order_estimated_delivery_date::date AS estimated_date,
  CASE
    WHEN o.order_status = 'delivered'
     AND o.order_delivered_customer_date IS NOT NULL
    THEN (o.order_delivered_customer_date::date - o.order_purchase_timestamp::date)
    ELSE NULL
  END AS delivery_days,
  CASE
    WHEN o.order_status = 'delivered'
     AND o.order_delivered_customer_date IS NOT NULL
     AND o.order_estimated_delivery_date IS NOT NULL
     AND o.order_delivered_customer_date::date > o.order_estimated_delivery_date::date
    THEN 1 ELSE 0
  END AS is_late,
  c.customer_unique_id,
  c.customer_city,
  c.customer_state
FROM olist_orders_dataset o
JOIN olist_customers_dataset c ON c.customer_id = o.customer_id;


CREATE OR REPLACE VIEW bi_fact_sales AS
SELECT
  oi.order_id,
  oi.order_item_id,
  oi.product_id,
  oi.seller_id,
  oi.shipping_limit_date::date AS shipping_limit_date,
  oi.price,
  oi.freight_value,
  fo.customer_id,
  fo.customer_unique_id,
  fo.order_status,
  fo.purchase_date,
  fo.purchase_month,
  fo.delivered_date,
  fo.estimated_date,
  fo.delivery_days,
  fo.is_late,
  fo.customer_city,
  fo.customer_state,
  dp.category,
  r.review_score,
  p.payment_type,
  p.payment_installments,
  p.payment_value,
  s.seller_city,
  s.seller_state
FROM olist_order_items_dataset oi
JOIN bi_fact_order fo ON fo.order_id = oi.order_id
LEFT JOIN bi_dim_product dp ON dp.product_id = oi.product_id
LEFT JOIN bi_fact_review_latest r ON r.order_id = oi.order_id
LEFT JOIN olist_order_payments_dataset p ON p.order_id = oi.order_id
LEFT JOIN olist_sellers_dataset s ON s.seller_id = oi.seller_id;


CREATE OR REPLACE VIEW bi_payments_order AS
SELECT
  op.order_id,
  SUM(op.payment_value) AS order_payment_value,
  MAX(op.payment_installments) AS order_payment_installments,
  (ARRAY_AGG(op.payment_type ORDER BY op.payment_value DESC NULLS LAST))[1] AS order_payment_type
FROM olist_order_payments_dataset op
GROUP BY op.order_id;
 select * from bi_dim_product

--*********************DATE DIMENSION************************
DimDate =
ADDCOLUMNS(
    CALENDAR(
        MIN('public bi_fact_sales'[purchase_date]),
        MAX('public bi_fact_sales'[purchase_date])
    ),
    "Year", YEAR([Date]),
    "Month No", MONTH([Date]),
    "Month", FORMAT([Date], "MMM"),
    "Year-Month", FORMAT([Date], "YYYY-MM"),
    "Quarter", "Q" & FORMAT([Date], "Q"),
    "Weekday No", WEEKDAY([Date], 2),
    "Weekday", FORMAT([Date], "DDD"),
    "Month Start", DATE(YEAR([Date]), MONTH([Date]), 1)
)
--**************************DAX MEASURES***************************
-- Base Measures --

Revenue := SUM ( 'public bi_fact_sales'[price] )

Freight := SUM ( 'public bi_fact_sales'[freight_value] )

GMV := [Revenue] + [Freight]

Orders := DISTINCTCOUNT ( 'public bi_fact_sales'[order_id] )

Customers := DISTINCTCOUNT ( 'public bi_fact_sales'[customer_unique_id] )

Items Sold := COUNTROWS ( 'public bi_fact_sales' )

AOV := DIVIDE ( [Revenue], [Orders] )

Items per Order := DIVIDE ( [Items Sold], [Orders] )

Avg Rating := AVERAGE ( 'public bi_fact_sales'[review_score] )

Delivered Orders :=
CALCULATE ( [Orders], 'public bi_fact_sales'[order_status] = "delivered" )

Late Orders :=
CALCULATE ( [Orders], 'public bi_fact_sales'[order_status] = "delivered", 'public bi_fact_sales'[is_late] = 1 )

On-time % :=
DIVIDE ( [Delivered Orders] - [Late Orders], [Delivered Orders] )


-- Time Measures --

Revenue YTD := TOTALYTD ( [Revenue], DimDate[Date] )

Revenue LY :=
CALCULATE ( [Revenue], SAMEPERIODLASTYEAR ( DimDate[Date] ) )

YoY % := DIVIDE ( [Revenue] - [Revenue LY], [Revenue LY] )

Rolling 30D Revenue :=
CALCULATE(
    [Revenue],
    DATESINPERIOD ( DimDate[Date], MAX ( DimDate[Date] ), -30, DAY )
)



-- Review Sentiment Measures --

Positive Reviews % :=
DIVIDE(
    CALCULATE( COUNTROWS('public bi_fact_sales'), 'public bi_fact_sales'[review_score] >= 4 ),
    CALCULATE( COUNTROWS('public bi_fact_sales'), NOT ISBLANK('public bi_fact_sales'[review_score]) )
)

Negative Reviews % :=
DIVIDE(
    CALCULATE( COUNTROWS('public bi_fact_sales'), 'public bi_fact_sales'[review_score] <= 2 ),
    CALCULATE( COUNTROWS('public bi_fact_sales'), NOT ISBLANK('public bi_fact_sales'[review_score]) )
)



-- Payments Measures--

Payment Value := SUM ( 'public bi_fact_sales'[payment_value] )

Avg Installments := AVERAGE ( 'public bi_fact_sales'[payment_installments] )

-- Page 5 -- Dilevery & Logistics -- 

Avg Delivery Days :=
AVERAGE ( 'public bi_fact_sales'[delivery_days] )


Late % := DIVIDE( [Late Orders], [Delivered Orders] )



-- Page 6 -- Reviews

Review Bucket :=
SWITCH(
    TRUE(),
    ISBLANK('public bi_fact_sales'[review_score]), "No Review",
   'public bi_fact_sales'[review_score] >= 4, "Positive (4-5)",
    'public bi_fact_sales'[review_score] = 3, "Neutral (3)",
    "Negative (1-2)"
)


-- Page 8 -- Seller 

Sellers := DISTINCTCOUNT ( 'public bi_fact_sales'[seller_id] )

Revenue per Seller := DIVIDE ( [Revenue], [Sellers] )


-- Page 9 -- Drillthrough

Drill Title = 
"Drillthrough: " &
COALESCE( SELECTEDVALUE('public bi_fact_sales'[category]), "All" )



