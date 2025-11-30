-- 1. Add 'url' column to cpi_establishments if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'cpi_establishments' AND column_name = 'url') THEN
        ALTER TABLE public.cpi_establishments ADD COLUMN url TEXT;
    END IF;
END $$;

-- 2. Create RPC to get products to scrape
-- Returns products that have fewer than 5 prices recorded for the current month
-- (assuming 5 target retailers: Walmart, Bodega, Chedraui, Soriana, La Comer)
CREATE OR REPLACE FUNCTION public.get_products_to_scrape(p_limit INTEGER DEFAULT 3)
RETURNS TABLE (
    product_id BIGINT,
    ean_code TEXT,
    product_name TEXT,
    country_id BIGINT,
    category_id BIGINT,
    prices_count BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        p.product_id,
        p.ean_code,
        p.product_name,
        p.country_id,
        p.category_id,
        COUNT(pr.price_id) as prices_count
    FROM 
        public.cpi_products p
    LEFT JOIN 
        public.cpi_prices pr ON p.product_id = pr.product_id 
        AND date_trunc('month', pr.date) = date_trunc('month', CURRENT_DATE)
    WHERE 
        p.is_active_product = TRUE
    GROUP BY 
        p.product_id
    HAVING 
        COUNT(pr.price_id) < 5 -- Assuming 5 retailers
    ORDER BY 
        prices_count ASC, -- Prioritize those with fewest prices (or 0)
        p.product_id ASC
    LIMIT 
        p_limit;
END;
$$;
