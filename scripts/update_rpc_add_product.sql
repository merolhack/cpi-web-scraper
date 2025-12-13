-- Update function to accept p_user_id
-- If p_user_id is provided, use it. usage: Main Scraper.
-- If p_user_id is NULL, use auth.uid(). usage: Mobile App / Web App Users.

CREATE OR REPLACE FUNCTION "public"."add_product_and_price"(
    "p_product_name" "text", 
    "p_ean_code" "text", 
    "p_country_id" bigint, 
    "p_category_id" bigint, 
    "p_establishment_id" bigint, 
    "p_location_id" bigint, 
    "p_price_value" numeric, 
    "p_price_date" "date",
    "p_user_id" uuid DEFAULT NULL
) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_product_id BIGINT;
    v_final_user_id UUID;
BEGIN
    -- Determine User ID
    IF p_user_id IS NOT NULL THEN
        v_final_user_id := p_user_id;
    ELSE
        v_final_user_id := auth.uid();
    END IF;

    -- Validate User ID (Optional but recommended for data integrity, though cpi_prices might allow null? No, schema likely requires it)
    -- If no user ID is available (script running without explicit ID and no auth), we might fallback to NULL if table allows, or raise error.
    -- cpi_prices.user_id might be nullable? Let's assume it should be set.
    
    -- Paso 1: Intentar encontrar el producto por su código EAN
    SELECT product_id INTO v_product_id
    FROM public.cpi_products
    WHERE ean_code = p_ean_code
    LIMIT 1;

    -- Paso 2: Si el producto no existe, crearlo
    IF v_product_id IS NULL THEN
        INSERT INTO public.cpi_products (country_id, category_id, product_name, ean_code, is_active_product)
        VALUES (p_country_id, p_category_id, p_product_name, p_ean_code, TRUE)
        RETURNING product_id INTO v_product_id;
    END IF;

    -- Paso 3: Insertar el precio usando el ID del producto (existente o nuevo)
    INSERT INTO public.cpi_prices (product_id, establishment_id, location_id, user_id, price_value, date, is_valid)
    VALUES (
        v_product_id,
        p_establishment_id,
        p_location_id,
        v_final_user_id, -- Used the determined user ID
        p_price_value,
        p_price_date,
        TRUE
    );

    -- Devolver el ID del precio recién insertado
    RETURN (SELECT currval(pg_get_serial_sequence('cpi_prices', 'price_id')));
END;
$$;

ALTER FUNCTION "public"."add_product_and_price"("p_product_name" "text", "p_ean_code" "text", "p_country_id" bigint, "p_category_id" bigint, "p_establishment_id" bigint, "p_location_id" bigint, "p_price_value" numeric, "p_price_date" "date", "p_user_id" uuid) OWNER TO "postgres";
