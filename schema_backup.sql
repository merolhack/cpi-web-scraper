


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."add_product_and_price"("p_product_name" "text", "p_ean_code" "text", "p_country_id" bigint, "p_category_id" bigint, "p_establishment_id" bigint, "p_location_id" bigint, "p_price_value" numeric, "p_price_date" "date") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_product_id BIGINT;
BEGIN
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
        auth.uid(), -- Obtiene el UUID del usuario autenticado que realiza la llamada
        p_price_value,
        p_price_date,
        TRUE
    );

    -- Devolver el ID del precio recién insertado
    RETURN (SELECT currval(pg_get_serial_sequence('cpi_prices', 'price_id')));
END;
$$;


ALTER FUNCTION "public"."add_product_and_price"("p_product_name" "text", "p_ean_code" "text", "p_country_id" bigint, "p_category_id" bigint, "p_establishment_id" bigint, "p_location_id" bigint, "p_price_value" numeric, "p_price_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_category"("p_name" "text") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_id BIGINT;
BEGIN
  INSERT INTO cpi_categories (name)
  VALUES (p_name)
  RETURNING id INTO v_id;
  
  RETURN v_id;
END;
$$;


ALTER FUNCTION "public"."create_category"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."deactivate_product_tracking"("p_tracking_id" bigint) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
  v_result JSON;
BEGIN
  v_user_id := auth.uid();
  
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  -- Actualizar el tracking
  UPDATE public.cpi_tracking
  SET is_active_tracking = FALSE
  WHERE tracking_id = p_tracking_id
    AND user_id = v_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tracking no encontrado';
  END IF;

  v_result := json_build_object(
    'success', true,
    'message', 'El producto ha sido removido de tu lista de seguimiento'
  );

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."deactivate_product_tracking"("p_tracking_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_dashboard_stats"() RETURNS TABLE("total_volunteers" bigint, "total_products" bigint, "total_prices" bigint, "pending_withdrawals" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN QUERY SELECT
    (SELECT COUNT(DISTINCT user_id) FROM cpi_tracking),
    (SELECT COUNT(*) FROM cpi_products),
    (SELECT COUNT(*) FROM cpi_prices),
    (SELECT COUNT(*) FROM cpi_withdrawals WHERE sent_date IS NULL); -- Pending = not sent yet
END;
$$;


ALTER FUNCTION "public"."get_admin_dashboard_stats"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_all_categories_admin"() RETURNS TABLE("id" bigint, "name" "text", "product_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    c.name,
    COUNT(p.id) as product_count
  FROM cpi_categories c
  LEFT JOIN cpi_products p ON c.id = p.category_id
  GROUP BY c.id, c.name
  ORDER BY c.name;
END;
$$;


ALTER FUNCTION "public"."get_all_categories_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_all_establishments_admin"() RETURNS TABLE("id" bigint, "name" "text", "country_name" "text", "location_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    e.establishment_id as id,
    e.establishment_name as name,
    c.country_name,
    COUNT(DISTINCT l.location_id) as location_count
  FROM cpi_establishments e
  JOIN cpi_countries c ON e.country_id = c.country_id
  LEFT JOIN cpi_locations l ON e.country_id = l.country_id -- Approximation, ideally establishments are linked to locations via prices or tracking
  GROUP BY e.establishment_id, e.establishment_name, c.country_name
  ORDER BY e.establishment_name;
END;
$$;


ALTER FUNCTION "public"."get_all_establishments_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_available_products_for_tracking"("p_country_id" bigint, "p_location_id" bigint, "p_establishment_id" bigint) RETURNS TABLE("product_id" bigint, "product_name" "text", "category_name" "text", "branch_name" "text", "product_photo_url" "text", "already_tracking" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
BEGIN
  v_user_id := auth.uid();
  
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  RETURN QUERY
  SELECT 
    p.product_id,
    p.product_name,
    c.category_name,
    b.branch_name,
    p.product_photo_url,
    EXISTS (
      SELECT 1 
      FROM public.cpi_tracking t
      WHERE t.product_id = p.product_id
        AND t.location_id = p_location_id
        AND t.establishment_id = p_establishment_id
        AND t.user_id = v_user_id
        AND t.is_active_tracking = TRUE
    ) as already_tracking
  FROM public.cpi_products p
  INNER JOIN public.cpi_categories c ON p.category_id = c.category_id
  INNER JOIN public.cpi_branches b ON c.branch_id = b.branch_id
  WHERE p.country_id = p_country_id
    AND p.is_active_product = TRUE
    -- Excluir productos actualizados recientemente en esta combinación
    AND NOT EXISTS (
      SELECT 1
      FROM public.cpi_prices pr
      WHERE pr.product_id = p.product_id
        AND pr.location_id = p_location_id
        AND pr.establishment_id = p_establishment_id
        AND pr.date > CURRENT_DATE - INTERVAL '60 days'
    )
  ORDER BY b.branch_name, c.category_name, p.product_name;
END;
$$;


ALTER FUNCTION "public"."get_available_products_for_tracking"("p_country_id" bigint, "p_location_id" bigint, "p_establishment_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_best_proxy_mx"() RETURNS json
    LANGUAGE "plpgsql"
    AS $$
declare
  selected_proxy record;
begin
  -- Select best proxy: active, MX, lowest fail_count, lowest latency
  -- Also prioritize proxies not used recently (or never used) to distribute load? 
  -- For now, simple greedy approach as requested.
  
  update public.cpi_proxies
  set last_used = now()
  where proxy_id = (
    select proxy_id
    from public.cpi_proxies
    where status = 'active' and country_code = 'MX'
    order by fail_count asc, latency_ms asc
    limit 1
    for update skip locked
  )
  returning * into selected_proxy;
  
  if selected_proxy is null then
    return null;
  end if;
  
  return row_to_json(selected_proxy);
end;
$$;


ALTER FUNCTION "public"."get_best_proxy_mx"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_finance_history"() RETURNS TABLE("id" bigint, "points_change" numeric, "reason" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    f.finance_id,
    f.amount,
    f.concept,
    f.date
  FROM cpi_finances f
  WHERE f.user_id = auth.uid()
  ORDER BY f.date DESC
  LIMIT 100;
END;
$$;


ALTER FUNCTION "public"."get_finance_history"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_latest_prices_by_country"("p_country_id" bigint) RETURNS TABLE("product_name" "text", "category_name" "text", "establishment_name" "text", "price_value" numeric)
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT ON (p.product_id, e.establishment_id)
        p.product_name,
        c.category_name,
        e.establishment_name,
        pr.price_value
    FROM
        public.cpi_prices pr
    JOIN
        public.cpi_products p ON pr.product_id = p.product_id
    JOIN
        public.cpi_establishments e ON pr.establishment_id = e.establishment_id
    JOIN
        public.cpi_categories c ON p.category_id = c.category_id
    WHERE
        p.country_id = p_country_id
        AND p.is_active_product = TRUE
    ORDER BY
        p.product_id, e.establishment_id, pr.date DESC;
END;
$$;


ALTER FUNCTION "public"."get_latest_prices_by_country"("p_country_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_pending_withdrawals"() RETURNS TABLE("id" bigint, "user_id" "uuid", "amount_points" numeric, "wallet_address" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    w.withdrawal_id,
    w.user_id,
    w.amount,
    w.concept as wallet_address,
    w.request_date
  FROM cpi_withdrawals w
  WHERE w.sent_date IS NULL
  ORDER BY w.request_date ASC;
END;
$$;


ALTER FUNCTION "public"."get_pending_withdrawals"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_product_price_history"("p_tracking_id" bigint) RETURNS TABLE("price_value" numeric, "date" "date", "photo_url" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_product_id BIGINT;
BEGIN
  SELECT product_id INTO v_product_id
  FROM cpi_tracking
  WHERE tracking_id = p_tracking_id;

  RETURN QUERY
  SELECT 
    pr.price_value,
    pr.date,
    pr.price_photo_url as photo_url
  FROM cpi_prices pr
  WHERE pr.product_id = v_product_id
  ORDER BY pr.date DESC
  LIMIT 20;
END;
$$;


ALTER FUNCTION "public"."get_product_price_history"("p_tracking_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_products_needing_update"() RETURNS TABLE("tracking_id" bigint, "product_name" "text", "location_name" "text", "establishment_name" "text", "last_update_date" "date", "days_since_update" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
BEGIN
  v_user_id := auth.uid();
  
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  RETURN QUERY
  SELECT 
    t.tracking_id,
    p.product_name,
    l.location_name,
    e.establishment_name,
    COALESCE(MAX(pr.date), '1900-01-01'::DATE) as last_update_date,
    CURRENT_DATE - COALESCE(MAX(pr.date), '1900-01-01'::DATE) as days_since_update
  FROM public.cpi_tracking t
  INNER JOIN public.cpi_products p ON t.product_id = p.product_id
  INNER JOIN public.cpi_locations l ON t.location_id = l.location_id
  INNER JOIN public.cpi_establishments e ON t.establishment_id = e.establishment_id
  LEFT JOIN public.cpi_prices pr ON 
    pr.product_id = t.product_id 
    AND pr.location_id = t.location_id
    AND pr.establishment_id = t.establishment_id
    AND pr.user_id = v_user_id
  WHERE t.user_id = v_user_id
    AND t.is_active_tracking = TRUE
  GROUP BY t.tracking_id, p.product_name, l.location_name, e.establishment_name
  HAVING CURRENT_DATE - COALESCE(MAX(pr.date), '1900-01-01'::DATE) > 30
  ORDER BY days_since_update DESC;
END;
$$;


ALTER FUNCTION "public"."get_products_needing_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_products_with_significant_changes"() RETURNS TABLE("product_id" bigint, "product_name" "text", "product_photo_url" "text", "current_price" numeric, "previous_price" numeric, "price_change_percentage" numeric, "last_update_date" timestamp with time zone, "establishment_name" "text", "location_name" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    WITH LatestPrices AS (
        SELECT 
            p.product_id,
            p.price_value,
            p.date,
            p.establishment_id,
            p.location_id,
            ROW_NUMBER() OVER (PARTITION BY p.product_id ORDER BY p.date DESC) as rn
        FROM 
            cpi_prices p
        WHERE 
            p.is_valid = true
    ),
    PriceComparison AS (
        SELECT 
            curr.product_id,
            curr.price_value as current_price,
            prev.price_value as previous_price,
            curr.date as last_update_date,
            curr.establishment_id,
            curr.location_id,
            ((curr.price_value - prev.price_value) / prev.price_value) * 100 as change_percentage
        FROM 
            LatestPrices curr
        JOIN 
            LatestPrices prev ON curr.product_id = prev.product_id AND prev.rn = 2
        WHERE 
            curr.rn = 1
    )
    SELECT 
        prod.product_id,
        prod.product_name,
        prod.product_photo_url,
        pc.current_price,
        pc.previous_price,
        pc.change_percentage as price_change_percentage,
        pc.last_update_date::TIMESTAMP WITH TIME ZONE,
        est.establishment_name,
        loc.location_name
    FROM 
        PriceComparison pc
    JOIN 
        cpi_products prod ON pc.product_id = prod.product_id
    JOIN 
        cpi_establishments est ON pc.establishment_id = est.establishment_id
    JOIN 
        cpi_locations loc ON pc.location_id = loc.location_id
    WHERE 
        ABS(pc.change_percentage) > 5 -- Mostrar solo cambios mayores al 5% (positivo o negativo)
    ORDER BY 
        ABS(pc.change_percentage) DESC
    LIMIT 10;
END;
$$;


ALTER FUNCTION "public"."get_products_with_significant_changes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_volunteer_dashboard"() RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
  v_volunteer_name TEXT;
  v_current_balance NUMERIC;
  v_products_needing_update INTEGER;
  v_result JSON;
BEGIN
  -- Obtener el user_id del usuario autenticado
  v_user_id := auth.uid();
  
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  -- Obtener nombre del voluntario
  SELECT name INTO v_volunteer_name
  FROM public.cpi_volunteers
  WHERE user_id = v_user_id;

  -- Obtener saldo actual
  SELECT COALESCE(current_balance, 0) INTO v_current_balance
  FROM public.cpi_finances
  WHERE user_id = v_user_id
  ORDER BY date DESC
  LIMIT 1;

  -- Contar productos que necesitan actualización (>30 días)
  SELECT COUNT(*) INTO v_products_needing_update
  FROM public.cpi_tracking t
  WHERE t.user_id = v_user_id
    AND t.is_active_tracking = TRUE
    AND NOT EXISTS (
      SELECT 1
      FROM public.cpi_prices p
      WHERE p.product_id = t.product_id
        AND p.location_id = t.location_id
        AND p.establishment_id = t.establishment_id
        AND p.user_id = v_user_id
        AND p.date > CURRENT_DATE - INTERVAL '30 days'
    );

  -- Construir respuesta
  v_result := json_build_object(
    'name', v_volunteer_name,
    'current_balance', v_current_balance,
    'products_needing_update', v_products_needing_update
  );

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_volunteer_dashboard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_volunteer_dashboard_stats"() RETURNS TABLE("current_points" bigint, "products_tracked_count" bigint, "pending_updates_count" bigint, "rank_name" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
  v_points NUMERIC;
  v_tracked_count BIGINT;
  v_pending_count BIGINT;
BEGIN
  v_user_id := auth.uid();
  
  -- Get current balance from latest finance record
  SELECT COALESCE(current_balance, 0) INTO v_points
  FROM cpi_finances
  WHERE user_id = v_user_id
  ORDER BY date DESC
  LIMIT 1;
  
  -- Get tracked products count
  SELECT COUNT(*) INTO v_tracked_count
  FROM cpi_tracking
  WHERE user_id = v_user_id AND is_active_tracking = true;
  
  -- Get pending updates count (products not updated in > 30 days)
  SELECT COUNT(*) INTO v_pending_count
  FROM cpi_tracking t
  JOIN cpi_products p ON t.product_id = p.product_id
  LEFT JOIN (
    SELECT product_id, MAX(date) as last_price_date
    FROM cpi_prices
    WHERE user_id = v_user_id
    GROUP BY product_id
  ) lp ON p.product_id = lp.product_id
  WHERE t.user_id = v_user_id 
  AND t.is_active_tracking = true
  AND (lp.last_price_date IS NULL OR lp.last_price_date < CURRENT_DATE - INTERVAL '30 days');

  RETURN QUERY SELECT 
    v_points::BIGINT,
    v_tracked_count,
    v_pending_count,
    'Voluntario'::TEXT;
END;
$$;


ALTER FUNCTION "public"."get_volunteer_dashboard_stats"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_volunteer_finance_history"("p_limit" integer DEFAULT 100) RETURNS TABLE("finance_id" bigint, "concept" "text", "date" timestamp with time zone, "amount" numeric, "current_balance" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
BEGIN
  v_user_id := auth.uid();
  
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  RETURN QUERY
  SELECT 
    f.finance_id,
    f.concept,
    f.date,
    f.amount,
    f.current_balance
  FROM public.cpi_finances f
  WHERE f.user_id = v_user_id
  ORDER BY f.date DESC
  LIMIT p_limit;
END;
$$;


ALTER FUNCTION "public"."get_volunteer_finance_history"("p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_volunteers"() RETURNS TABLE("user_id" "uuid", "email" "text", "products_tracked" bigint, "total_points" numeric, "last_active" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    v.user_id,
    v.email,
    COUNT(DISTINCT t.product_id) as products_tracked,
    COALESCE((
      SELECT current_balance 
      FROM cpi_finances f 
      WHERE f.user_id = v.user_id 
      ORDER BY f.date DESC 
      LIMIT 1
    ), 0) as total_points,
    MAX(f.date) as last_active
  FROM cpi_volunteers v
  LEFT JOIN cpi_tracking t ON v.user_id = t.user_id AND t.is_active_tracking = true
  LEFT JOIN cpi_finances f ON v.user_id = f.user_id
  GROUP BY v.user_id, v.email;
END;
$$;


ALTER FUNCTION "public"."get_volunteers"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_volunteers_needing_reminders"() RETURNS TABLE("user_id" "uuid", "email" "text", "pending_products_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    t.user_id,
    'user@example.com'::TEXT as email, -- Placeholder, would need auth.users access
    COUNT(DISTINCT t.product_id) as pending_products_count
  FROM cpi_tracking t
  LEFT JOIN (
    SELECT product_id, MAX(date) as last_price_date
    FROM cpi_prices
    GROUP BY product_id
  ) lp ON t.product_id = lp.product_id
  WHERE t.is_active = true
  AND (lp.last_price_date IS NULL OR lp.last_price_date < NOW() - INTERVAL '30 days')
  GROUP BY t.user_id
  HAVING COUNT(DISTINCT t.product_id) > 0;
END;
$$;


ALTER FUNCTION "public"."get_volunteers_needing_reminders"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_withdrawal_history"() RETURNS TABLE("id" bigint, "amount_points" numeric, "wallet_address" "text", "status" "text", "created_at" timestamp with time zone, "processed_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    w.withdrawal_id,
    w.amount,
    w.concept as wallet_address, -- concept stores the wallet address
    CASE WHEN w.sent_date IS NULL THEN 'pending' ELSE 'processed' END as status,
    w.request_date,
    w.sent_date
  FROM cpi_withdrawals w
  WHERE w.user_id = auth.uid()
  ORDER BY w.request_date DESC;
END;
$$;


ALTER FUNCTION "public"."get_withdrawal_history"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Insert into cpi_users
  INSERT INTO public.cpi_users (user_id, email)
  VALUES (new.id, new.email);

  -- Insert into cpi_volunteers (defaulting to not suspended)
  -- We use a default name 'Volunteer' because the column is NOT NULL
  INSERT INTO public.cpi_volunteers (user_id, email, name, suspended)
  VALUES (
    new.id, 
    new.email, 
    COALESCE(new.raw_user_meta_data->>'full_name', 'Volunteer'), 
    false
  );

  RETURN new;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_withdrawal"("p_withdrawal_id" bigint, "p_status" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_withdrawal_amount NUMERIC;
  v_withdrawal_user_id UUID;
  v_current_balance NUMERIC;
  v_new_balance NUMERIC;
BEGIN
  -- Get withdrawal details
  SELECT amount, user_id INTO v_withdrawal_amount, v_withdrawal_user_id
  FROM cpi_withdrawals
  WHERE withdrawal_id = p_withdrawal_id;
  
  IF p_status = 'processed' THEN
    -- Mark as sent
    UPDATE cpi_withdrawals
    SET sent_date = NOW()
    WHERE withdrawal_id = p_withdrawal_id;
  ELSIF p_status = 'rejected' THEN
    -- Delete withdrawal request
    DELETE FROM cpi_withdrawals WHERE withdrawal_id = p_withdrawal_id;
    
    -- Refund points
    SELECT COALESCE(current_balance, 0) INTO v_current_balance
    FROM cpi_finances
    WHERE user_id = v_withdrawal_user_id
    ORDER BY date DESC
    LIMIT 1;
    
    v_new_balance := v_current_balance + v_withdrawal_amount;
    
    INSERT INTO cpi_finances (user_id, concept, date, previous_balance, amount, current_balance)
    VALUES (v_withdrawal_user_id, 'Withdrawal Rejected - Refund', NOW(), v_current_balance, v_withdrawal_amount, v_new_balance);
  END IF;
END;
$$;


ALTER FUNCTION "public"."process_withdrawal"("p_withdrawal_id" bigint, "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recalculate_daily_cpi"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- This is a placeholder for the actual CPI calculation logic
  -- The real implementation would:
  -- 1. Get the latest prices for each product
  -- 2. Calculate weighted averages
  -- 3. Update the cpi_real_cpi table
  
  RAISE NOTICE 'CPI recalculation would run here';
  
  -- Example: Update a log table to track when this ran
  -- INSERT INTO cpi_system_logs (event_type, message, created_at)
  -- VALUES ('cpi_recalculation', 'Daily CPI recalculation completed', NOW());
END;
$$;


ALTER FUNCTION "public"."recalculate_daily_cpi"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_volunteer"("p_user_id" "uuid", "p_email" "text", "p_name" "text", "p_country_id" bigint) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_result JSON;
BEGIN
  -- Validación 1: Verificar si el email ya existe en cpi_volunteers
  IF EXISTS (SELECT 1 FROM public.cpi_volunteers WHERE email = p_email) THEN
    v_result := json_build_object(
      'success', false,
      'error_code', 'EMAIL_EXISTS',
      'message', 'Este correo electrónico ya está registrado'
    );
    RETURN v_result;
  END IF;

  -- Validación 2: Verificar si el user_id ya existe
  IF EXISTS (SELECT 1 FROM public.cpi_volunteers WHERE user_id = p_user_id) THEN
    v_result := json_build_object(
      'success', false,
      'error_code', 'USER_EXISTS',
      'message', 'Este usuario ya está registrado'
    );
    RETURN v_result;
  END IF;

  -- Validación 3: Verificar que el nombre no esté vacío
  IF LENGTH(TRIM(p_name)) < 2 THEN
    v_result := json_build_object(
      'success', false,
      'error_code', 'INVALID_NAME',
      'message', 'El nombre debe tener al menos 2 caracteres'
    );
    RETURN v_result;
  END IF;

  -- 1. Insertar en cpi_users
  INSERT INTO public.cpi_users (user_id, email)
  VALUES (p_user_id, p_email)
  ON CONFLICT (user_id) DO NOTHING;

  -- 2. Insertar en cpi_volunteers
  INSERT INTO public.cpi_volunteers (
    user_id, 
    email, 
    name, 
    country_id, 
    suspended
  )
  VALUES (
    p_user_id, 
    p_email, 
    p_name, 
    p_country_id, 
    FALSE
  );

  -- 3. Crear registro inicial de finanzas
  INSERT INTO public.cpi_finances (
    user_id, 
    concept, 
    previous_balance, 
    amount, 
    current_balance,
    date
  )
  VALUES (
    p_user_id, 
    'Saldo inicial', 
    0, 
    0, 
    0,
    NOW()
  );

  -- Respuesta exitosa
  v_result := json_build_object(
    'success', true,
    'user_id', p_user_id,
    'message', 'Registro completado exitosamente'
  );

  RETURN v_result;

EXCEPTION
  WHEN unique_violation THEN
    -- Manejo específico para violaciones de unicidad
    v_result := json_build_object(
      'success', false,
      'error_code', 'DUPLICATE_ENTRY',
      'message', 'Este correo electrónico ya está registrado'
    );
    RETURN v_result;
  WHEN OTHERS THEN
    -- Cualquier otro error
    v_result := json_build_object(
      'success', false,
      'error_code', 'SYSTEM_ERROR',
      'message', 'Ocurrió un error al procesar tu registro. Por favor intenta más tarde.'
    );
    RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."register_volunteer"("p_user_id" "uuid", "p_email" "text", "p_name" "text", "p_country_id" bigint) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."register_volunteer"("p_user_id" "uuid", "p_email" "text", "p_name" "text", "p_country_id" bigint) IS 'Registra un nuevo voluntario en el sistema. Puede ser ejecutada por usuarios anónimos durante el signup.';



CREATE OR REPLACE FUNCTION "public"."request_withdrawal"("p_amount" integer, "p_wallet_address" "text") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
  v_current_balance NUMERIC;
  v_withdrawal_id BIGINT;
  v_new_balance NUMERIC;
  v_previous_balance NUMERIC;
BEGIN
  v_user_id := auth.uid();
  
  -- Get current balance
  SELECT COALESCE(current_balance, 0) INTO v_current_balance
  FROM cpi_finances
  WHERE user_id = v_user_id
  ORDER BY date DESC
  LIMIT 1;
  
  IF v_current_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient points';
  END IF;
  
  -- Create withdrawal request
  INSERT INTO cpi_withdrawals (user_id, amount, concept, request_date)
  VALUES (v_user_id, p_amount, p_wallet_address, NOW())
  RETURNING withdrawal_id INTO v_withdrawal_id;
  
  -- Deduct points in finances
  v_previous_balance := v_current_balance;
  v_new_balance := v_current_balance - p_amount;
  
  INSERT INTO cpi_finances (user_id, concept, date, previous_balance, amount, current_balance)
  VALUES (v_user_id, 'Withdrawal Request', NOW(), v_previous_balance, -p_amount, v_new_balance);
  
  RETURN v_withdrawal_id;
END;
$$;


ALTER FUNCTION "public"."request_withdrawal"("p_amount" integer, "p_wallet_address" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."request_withdrawal"("p_amount" numeric, "p_polygon_address" "text") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
  v_current_balance NUMERIC;
  v_new_balance NUMERIC;
  v_finance_id BIGINT;
  v_withdrawal_id BIGINT;
  v_result JSON;
BEGIN
  v_user_id := auth.uid();
  
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  -- Obtener saldo actual
  SELECT COALESCE(current_balance, 0) INTO v_current_balance
  FROM public.cpi_finances
  WHERE user_id = v_user_id
  ORDER BY date DESC
  LIMIT 1;

  -- Validar que tenga suficiente saldo
  IF p_amount > v_current_balance THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Saldo insuficiente',
      'message', 'Solo puedes solicitar el retiro de ' || v_current_balance || ' puntos como máximo'
    );
  END IF;

  -- Validar cantidad mínima
  IF p_amount < 1 THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Cantidad inválida',
      'message', 'La cantidad mínima de retiro es 1 punto'
    );
  END IF;

  v_new_balance := v_current_balance - p_amount;

  -- Registrar movimiento financiero
  INSERT INTO public.cpi_finances (
    user_id,
    concept,
    date,
    previous_balance,
    amount,
    current_balance
  ) VALUES (
    v_user_id,
    'Retiro a Polygon ' || p_polygon_address,
    NOW(),
    v_current_balance,
    -p_amount,
    v_new_balance
  ) RETURNING finance_id INTO v_finance_id;

  -- Registrar solicitud de retiro
  INSERT INTO public.cpi_withdrawals (
    user_id,
    amount,
    concept,
    request_date,
    finance_id
  ) VALUES (
    v_user_id,
    p_amount,
    'Retiro a Polygon ' || p_polygon_address,
    NOW(),
    v_finance_id
  ) RETURNING withdrawal_id INTO v_withdrawal_id;

  v_result := json_build_object(
    'success', true,
    'withdrawal_id', v_withdrawal_id,
    'new_balance', v_new_balance,
    'message', 'Tu solicitud de retiro está en proceso. Recibirás un correo cuando sea enviado. Este proceso es manual y puede tardar de 1 a 72 horas.'
  );

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."request_withdrawal"("p_amount" numeric, "p_polygon_address" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."stop_tracking_product"("p_tracking_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  UPDATE cpi_tracking
  SET is_active_tracking = false
  WHERE tracking_id = p_tracking_id AND user_id = auth.uid();
END;
$$;


ALTER FUNCTION "public"."stop_tracking_product"("p_tracking_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_product_price"("p_tracking_id" bigint, "p_price_value" numeric, "p_date" "date", "p_photo_url" "text") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
  v_product_id BIGINT;
  v_location_id BIGINT;
  v_establishment_id BIGINT;
  v_product_name TEXT;
  v_location_name TEXT;
  v_establishment_name TEXT;
  v_price_id BIGINT;
  v_previous_balance NUMERIC;
  v_new_balance NUMERIC;
  v_last_price_date DATE;
  v_points_to_add INTEGER;
  v_result JSON;
BEGIN
  v_user_id := auth.uid();
  
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  -- Obtener información del tracking
  SELECT 
    t.product_id, 
    t.location_id, 
    t.establishment_id,
    p.product_name,
    l.location_name,
    e.establishment_name
  INTO 
    v_product_id, 
    v_location_id, 
    v_establishment_id,
    v_product_name,
    v_location_name,
    v_establishment_name
  FROM public.cpi_tracking t
  INNER JOIN public.cpi_products p ON t.product_id = p.product_id
  INNER JOIN public.cpi_locations l ON t.location_id = l.location_id
  INNER JOIN public.cpi_establishments e ON t.establishment_id = e.establishment_id
  WHERE t.tracking_id = p_tracking_id
    AND t.user_id = v_user_id;

  IF v_product_id IS NULL THEN
    RAISE EXCEPTION 'Tracking no encontrado';
  END IF;

  -- Obtener fecha del último precio registrado
  SELECT MAX(date) INTO v_last_price_date
  FROM public.cpi_prices
  WHERE product_id = v_product_id
    AND location_id = v_location_id
    AND establishment_id = v_establishment_id
    AND user_id = v_user_id;

  -- Determinar puntos a agregar (solo si han pasado >30 días)
  IF v_last_price_date IS NULL OR (p_date - v_last_price_date) > 30 THEN
    v_points_to_add := 1;
  ELSE
    v_points_to_add := 0;
  END IF;

  -- Insertar precio
  INSERT INTO public.cpi_prices (
    product_id,
    location_id,
    establishment_id,
    user_id,
    price_value,
    date,
    price_photo_url,
    is_valid
  ) VALUES (
    v_product_id,
    v_location_id,
    v_establishment_id,
    v_user_id,
    p_price_value,
    p_date,
    p_photo_url,
    TRUE
  ) RETURNING price_id INTO v_price_id;

  -- Agregar puntos si corresponde
  IF v_points_to_add > 0 THEN
    -- Obtener saldo anterior
    SELECT COALESCE(current_balance, 0) INTO v_previous_balance
    FROM public.cpi_finances
    WHERE user_id = v_user_id
    ORDER BY date DESC
    LIMIT 1;

    v_new_balance := v_previous_balance + v_points_to_add;

    -- Insertar movimiento financiero
    INSERT INTO public.cpi_finances (
      user_id,
      concept,
      date,
      previous_balance,
      amount,
      current_balance
    ) VALUES (
      v_user_id,
      'Actualización precio ' || v_product_name || ' en ' || v_establishment_name || ', ' || v_location_name,
      NOW(),
      v_previous_balance,
      v_points_to_add,
      v_new_balance
    );
  ELSE
    v_new_balance := (
      SELECT COALESCE(current_balance, 0)
      FROM public.cpi_finances
      WHERE user_id = v_user_id
      ORDER BY date DESC
      LIMIT 1
    );
  END IF;

  -- Construir respuesta
  v_result := json_build_object(
    'success', true,
    'price_id', v_price_id,
    'points_added', v_points_to_add,
    'new_balance', v_new_balance,
    'message', CASE 
      WHEN v_points_to_add > 0 THEN 'Precio actualizado. Has ganado ' || v_points_to_add || ' punto.'
      ELSE 'Precio actualizado.'
    END
  );

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."update_product_price"("p_tracking_id" bigint, "p_price_value" numeric, "p_date" "date", "p_photo_url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_product_price"("p_tracking_id" bigint, "p_price_value" numeric, "p_date" timestamp with time zone, "p_photo_url" "text" DEFAULT NULL::"text") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id UUID;
  v_product_id BIGINT;
  v_establishment_id BIGINT;
  v_location_id BIGINT;
  v_price_id BIGINT;
  v_current_balance NUMERIC;
  v_new_balance NUMERIC;
BEGIN
  v_user_id := auth.uid();
  
  SELECT product_id, establishment_id, location_id 
  INTO v_product_id, v_establishment_id, v_location_id
  FROM cpi_tracking
  WHERE tracking_id = p_tracking_id AND user_id = v_user_id AND is_active_tracking = true;
  
  IF v_product_id IS NULL THEN
    RAISE EXCEPTION 'Tracking not found or inactive';
  END IF;
  
  INSERT INTO cpi_prices (
    product_id, 
    establishment_id, 
    location_id, 
    price_value, 
    date, 
    user_id,
    price_photo_url
  )
  VALUES (
    v_product_id, 
    v_establishment_id, 
    v_location_id, 
    p_price_value, 
    p_date::DATE, 
    v_user_id,
    p_photo_url
  )
  RETURNING price_id INTO v_price_id;
  
  -- Award points if eligible (no update in last 30 days)
  IF NOT EXISTS (
    SELECT 1 FROM cpi_prices 
    WHERE product_id = v_product_id 
    AND user_id = v_user_id 
    AND date > (p_date::DATE - INTERVAL '30 days')
    AND price_id != v_price_id
  ) THEN
    -- Get current balance
    SELECT COALESCE(current_balance, 0) INTO v_current_balance
    FROM cpi_finances
    WHERE user_id = v_user_id
    ORDER BY date DESC
    LIMIT 1;
    
    v_new_balance := v_current_balance + 1;
    
    INSERT INTO cpi_finances (user_id, concept, date, previous_balance, amount, current_balance)
    VALUES (v_user_id, 'Price Update Reward', NOW(), v_current_balance, 1, v_new_balance);
  END IF;
  
  RETURN v_price_id;
END;
$$;


ALTER FUNCTION "public"."update_product_price"("p_tracking_id" bigint, "p_price_value" numeric, "p_date" timestamp with time zone, "p_photo_url" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."cpi_annual_product_location_establishment_inflation" (
    "aple_inflation_id" bigint NOT NULL,
    "recent_price_id" bigint,
    "product_id" bigint,
    "country_id" bigint,
    "location_id" bigint,
    "establishment_id" bigint,
    "recent_date" "date" NOT NULL,
    "historical_date" "date" NOT NULL,
    "days_between_measurements" integer NOT NULL,
    "recent_price_value" numeric NOT NULL,
    "historical_price_value" numeric NOT NULL,
    "aple_inflation_rate" numeric
);


ALTER TABLE "public"."cpi_annual_product_location_establishment_inflation" OWNER TO "postgres";


ALTER TABLE "public"."cpi_annual_product_location_establishment_inflation" ALTER COLUMN "aple_inflation_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_annual_product_location_establishment_aple_inflation_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_branches" (
    "branch_id" bigint NOT NULL,
    "branch_name" "text" NOT NULL
);


ALTER TABLE "public"."cpi_branches" OWNER TO "postgres";


ALTER TABLE "public"."cpi_branches" ALTER COLUMN "branch_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_branches_branch_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_categories" (
    "category_id" bigint NOT NULL,
    "branch_id" bigint,
    "category_name" "text" NOT NULL,
    "is_essential_category" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."cpi_categories" OWNER TO "postgres";


ALTER TABLE "public"."cpi_categories" ALTER COLUMN "category_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_categories_category_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_category_inflation" (
    "ci_id" bigint NOT NULL,
    "country_id" bigint,
    "category_id" bigint,
    "ci_inflation_rate" numeric,
    "update_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "month" integer NOT NULL,
    "year" integer NOT NULL
);


ALTER TABLE "public"."cpi_category_inflation" OWNER TO "postgres";


ALTER TABLE "public"."cpi_category_inflation" ALTER COLUMN "ci_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_category_inflation_ci_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_category_location_inflation" (
    "cli_id" bigint NOT NULL,
    "country_id" bigint,
    "category_id" bigint,
    "location_id" bigint,
    "cli_inflation_rate" numeric,
    "update_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "month" integer NOT NULL,
    "year" integer NOT NULL
);


ALTER TABLE "public"."cpi_category_location_inflation" OWNER TO "postgres";


ALTER TABLE "public"."cpi_category_location_inflation" ALTER COLUMN "cli_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_category_location_inflation_cli_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_countries" (
    "country_id" bigint NOT NULL,
    "country_name" "text" NOT NULL,
    "currency" "text" NOT NULL,
    "currency_code" "text" NOT NULL
);


ALTER TABLE "public"."cpi_countries" OWNER TO "postgres";


ALTER TABLE "public"."cpi_countries" ALTER COLUMN "country_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_countries_country_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_criteria" (
    "criterion_id" bigint NOT NULL,
    "criterion_name" "text" NOT NULL,
    "criterion_description" "text",
    "is_active_criterion" boolean DEFAULT true NOT NULL,
    "acceptance_score" numeric NOT NULL
);


ALTER TABLE "public"."cpi_criteria" OWNER TO "postgres";


ALTER TABLE "public"."cpi_criteria" ALTER COLUMN "criterion_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_criteria_criterion_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_establishment_categories" (
    "establishment_category_id" bigint NOT NULL,
    "establishment_id" bigint,
    "category_id" bigint
);


ALTER TABLE "public"."cpi_establishment_categories" OWNER TO "postgres";


ALTER TABLE "public"."cpi_establishment_categories" ALTER COLUMN "establishment_category_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_establishment_categories_establishment_category_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_establishments" (
    "establishment_id" bigint NOT NULL,
    "country_id" bigint,
    "establishment_name" "text" NOT NULL
);


ALTER TABLE "public"."cpi_establishments" OWNER TO "postgres";


ALTER TABLE "public"."cpi_establishments" ALTER COLUMN "establishment_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_establishments_establishment_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_finances" (
    "finance_id" bigint NOT NULL,
    "user_id" "uuid",
    "concept" "text" NOT NULL,
    "date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "previous_balance" numeric NOT NULL,
    "amount" numeric NOT NULL,
    "current_balance" numeric NOT NULL,
    CONSTRAINT "check_balance_non_negative" CHECK (("current_balance" >= (0)::numeric))
);


ALTER TABLE "public"."cpi_finances" OWNER TO "postgres";


ALTER TABLE "public"."cpi_finances" ALTER COLUMN "finance_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_finances_finance_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_locations" (
    "location_id" bigint NOT NULL,
    "country_id" bigint,
    "location_name" "text" NOT NULL,
    "population" integer NOT NULL
);


ALTER TABLE "public"."cpi_locations" OWNER TO "postgres";


ALTER TABLE "public"."cpi_locations" ALTER COLUMN "location_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_locations_location_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_prices" (
    "price_id" bigint NOT NULL,
    "product_id" bigint,
    "location_id" bigint,
    "establishment_id" bigint,
    "user_id" "uuid",
    "price_value" numeric(10,2) NOT NULL,
    "date" "date" NOT NULL,
    "price_photo_url" "text",
    "is_valid" boolean DEFAULT true NOT NULL,
    "analyzed_date" timestamp with time zone
);


ALTER TABLE "public"."cpi_prices" OWNER TO "postgres";


ALTER TABLE "public"."cpi_prices" ALTER COLUMN "price_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_prices_price_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_products" (
    "product_id" bigint NOT NULL,
    "country_id" bigint,
    "category_id" bigint,
    "product_name" "text" NOT NULL,
    "product_photo_url" "text",
    "is_active_product" boolean NOT NULL,
    "ean_code" "text"
);


ALTER TABLE "public"."cpi_products" OWNER TO "postgres";


ALTER TABLE "public"."cpi_products" ALTER COLUMN "product_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_products_product_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_proxies" (
    "proxy_id" bigint NOT NULL,
    "ip_address" "inet" NOT NULL,
    "port" integer NOT NULL,
    "protocol" "text" NOT NULL,
    "country_code" character(2) NOT NULL,
    "status" "text" DEFAULT 'unchecked'::"text" NOT NULL,
    "latency_ms" integer DEFAULT 9999,
    "fail_count" integer DEFAULT 0,
    "success_count" integer DEFAULT 0,
    "last_checked" timestamp with time zone DEFAULT "now"(),
    "last_used" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."cpi_proxies" OWNER TO "postgres";


ALTER TABLE "public"."cpi_proxies" ALTER COLUMN "proxy_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_proxies_proxy_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_real_cpi" (
    "real_cpi_id" bigint NOT NULL,
    "country_id" bigint,
    "criterion_id" bigint,
    "real_cpi_inflation_rate" numeric,
    "update_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "month" integer NOT NULL,
    "year" integer NOT NULL
);


ALTER TABLE "public"."cpi_real_cpi" OWNER TO "postgres";


ALTER TABLE "public"."cpi_real_cpi" ALTER COLUMN "real_cpi_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_real_cpi_real_cpi_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_tracking" (
    "tracking_id" bigint NOT NULL,
    "country_id" bigint,
    "product_id" bigint,
    "location_id" bigint,
    "establishment_id" bigint,
    "user_id" "uuid",
    "is_active_tracking" boolean NOT NULL
);


ALTER TABLE "public"."cpi_tracking" OWNER TO "postgres";


ALTER TABLE "public"."cpi_tracking" ALTER COLUMN "tracking_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_tracking_tracking_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_users" (
    "user_id" "uuid" NOT NULL,
    "email" "text" NOT NULL
);


ALTER TABLE "public"."cpi_users" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cpi_volunteers" (
    "user_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "name" "text" NOT NULL,
    "whatsapp" "text",
    "country_id" bigint,
    "suspended" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."cpi_volunteers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cpi_weights" (
    "weight_id" bigint NOT NULL,
    "criterion_id" bigint,
    "category_id" bigint,
    "weight_value" numeric DEFAULT 1 NOT NULL
);


ALTER TABLE "public"."cpi_weights" OWNER TO "postgres";


ALTER TABLE "public"."cpi_weights" ALTER COLUMN "weight_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_weights_weight_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cpi_withdrawals" (
    "withdrawal_id" bigint NOT NULL,
    "user_id" "uuid",
    "amount" numeric NOT NULL,
    "concept" "text" NOT NULL,
    "request_date" timestamp with time zone NOT NULL,
    "finance_id" bigint,
    "sent_date" timestamp with time zone
);


ALTER TABLE "public"."cpi_withdrawals" OWNER TO "postgres";


ALTER TABLE "public"."cpi_withdrawals" ALTER COLUMN "withdrawal_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."cpi_withdrawals_withdrawal_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."cpi_annual_product_location_establishment_inflation"
    ADD CONSTRAINT "cpi_annual_product_location_establishment_inflation_pkey" PRIMARY KEY ("aple_inflation_id");



ALTER TABLE ONLY "public"."cpi_branches"
    ADD CONSTRAINT "cpi_branches_branch_name_key" UNIQUE ("branch_name");



ALTER TABLE ONLY "public"."cpi_branches"
    ADD CONSTRAINT "cpi_branches_pkey" PRIMARY KEY ("branch_id");



ALTER TABLE ONLY "public"."cpi_categories"
    ADD CONSTRAINT "cpi_categories_pkey" PRIMARY KEY ("category_id");



ALTER TABLE ONLY "public"."cpi_category_inflation"
    ADD CONSTRAINT "cpi_category_inflation_pkey" PRIMARY KEY ("ci_id");



ALTER TABLE ONLY "public"."cpi_category_location_inflation"
    ADD CONSTRAINT "cpi_category_location_inflation_pkey" PRIMARY KEY ("cli_id");



ALTER TABLE ONLY "public"."cpi_countries"
    ADD CONSTRAINT "cpi_countries_country_name_key" UNIQUE ("country_name");



ALTER TABLE ONLY "public"."cpi_countries"
    ADD CONSTRAINT "cpi_countries_pkey" PRIMARY KEY ("country_id");



ALTER TABLE ONLY "public"."cpi_criteria"
    ADD CONSTRAINT "cpi_criteria_criterion_name_key" UNIQUE ("criterion_name");



ALTER TABLE ONLY "public"."cpi_criteria"
    ADD CONSTRAINT "cpi_criteria_pkey" PRIMARY KEY ("criterion_id");



ALTER TABLE ONLY "public"."cpi_establishment_categories"
    ADD CONSTRAINT "cpi_establishment_categories_pkey" PRIMARY KEY ("establishment_category_id");



ALTER TABLE ONLY "public"."cpi_establishments"
    ADD CONSTRAINT "cpi_establishments_pkey" PRIMARY KEY ("establishment_id");



ALTER TABLE ONLY "public"."cpi_finances"
    ADD CONSTRAINT "cpi_finances_pkey" PRIMARY KEY ("finance_id");



ALTER TABLE ONLY "public"."cpi_locations"
    ADD CONSTRAINT "cpi_locations_pkey" PRIMARY KEY ("location_id");



ALTER TABLE ONLY "public"."cpi_prices"
    ADD CONSTRAINT "cpi_prices_pkey" PRIMARY KEY ("price_id");



ALTER TABLE ONLY "public"."cpi_products"
    ADD CONSTRAINT "cpi_products_ean_code_key" UNIQUE ("ean_code");



ALTER TABLE ONLY "public"."cpi_products"
    ADD CONSTRAINT "cpi_products_pkey" PRIMARY KEY ("product_id");



ALTER TABLE ONLY "public"."cpi_proxies"
    ADD CONSTRAINT "cpi_proxies_pkey" PRIMARY KEY ("proxy_id");



ALTER TABLE ONLY "public"."cpi_proxies"
    ADD CONSTRAINT "cpi_proxies_unique_socket" UNIQUE ("ip_address", "port", "protocol");



ALTER TABLE ONLY "public"."cpi_real_cpi"
    ADD CONSTRAINT "cpi_real_cpi_pkey" PRIMARY KEY ("real_cpi_id");



ALTER TABLE ONLY "public"."cpi_tracking"
    ADD CONSTRAINT "cpi_tracking_pkey" PRIMARY KEY ("tracking_id");



ALTER TABLE ONLY "public"."cpi_users"
    ADD CONSTRAINT "cpi_users_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."cpi_users"
    ADD CONSTRAINT "cpi_users_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."cpi_volunteers"
    ADD CONSTRAINT "cpi_volunteers_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."cpi_volunteers"
    ADD CONSTRAINT "cpi_volunteers_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."cpi_weights"
    ADD CONSTRAINT "cpi_weights_pkey" PRIMARY KEY ("weight_id");



ALTER TABLE ONLY "public"."cpi_withdrawals"
    ADD CONSTRAINT "cpi_withdrawals_pkey" PRIMARY KEY ("withdrawal_id");



CREATE INDEX "idx_aple_country" ON "public"."cpi_annual_product_location_establishment_inflation" USING "btree" ("country_id");



CREATE INDEX "idx_aple_establishment" ON "public"."cpi_annual_product_location_establishment_inflation" USING "btree" ("establishment_id");



CREATE INDEX "idx_aple_location" ON "public"."cpi_annual_product_location_establishment_inflation" USING "btree" ("location_id");



CREATE INDEX "idx_aple_product" ON "public"."cpi_annual_product_location_establishment_inflation" USING "btree" ("product_id");



CREATE INDEX "idx_aple_recent_price" ON "public"."cpi_annual_product_location_establishment_inflation" USING "btree" ("recent_price_id");



CREATE INDEX "idx_cat_inf_category" ON "public"."cpi_category_inflation" USING "btree" ("category_id");



CREATE INDEX "idx_cat_inf_country" ON "public"."cpi_category_inflation" USING "btree" ("country_id");



CREATE INDEX "idx_cat_loc_inf_cat" ON "public"."cpi_category_location_inflation" USING "btree" ("category_id");



CREATE INDEX "idx_cat_loc_inf_country" ON "public"."cpi_category_location_inflation" USING "btree" ("country_id");



CREATE INDEX "idx_cat_loc_inf_loc" ON "public"."cpi_category_location_inflation" USING "btree" ("location_id");



CREATE INDEX "idx_categories_branch" ON "public"."cpi_categories" USING "btree" ("branch_id");



CREATE INDEX "idx_cpi_prices_date" ON "public"."cpi_prices" USING "btree" ("date" DESC);



CREATE INDEX "idx_cpi_prices_establishment_id" ON "public"."cpi_prices" USING "btree" ("establishment_id");



CREATE INDEX "idx_cpi_prices_location_id" ON "public"."cpi_prices" USING "btree" ("location_id");



CREATE INDEX "idx_cpi_prices_prod_est" ON "public"."cpi_prices" USING "btree" ("product_id", "establishment_id");



CREATE INDEX "idx_cpi_prices_product_id" ON "public"."cpi_prices" USING "btree" ("product_id");



CREATE INDEX "idx_cpi_products_category_id" ON "public"."cpi_products" USING "btree" ("category_id");



COMMENT ON INDEX "public"."idx_cpi_products_category_id" IS 'Index on category_id foreign key to improve query performance and foreign key constraint checks.';



CREATE INDEX "idx_cpi_proxies_active_mx" ON "public"."cpi_proxies" USING "btree" ("latency_ms", "fail_count") WHERE (("status" = 'active'::"text") AND ("country_code" = 'MX'::"bpchar"));



CREATE INDEX "idx_cpi_tracking_location_id" ON "public"."cpi_tracking" USING "btree" ("location_id");



CREATE INDEX "idx_cpi_tracking_user_product" ON "public"."cpi_tracking" USING "btree" ("user_id", "product_id");



CREATE INDEX "idx_cpi_withdrawals_user_id" ON "public"."cpi_withdrawals" USING "btree" ("user_id");



CREATE INDEX "idx_est_cat_category" ON "public"."cpi_establishment_categories" USING "btree" ("category_id");



CREATE INDEX "idx_est_cat_establishment" ON "public"."cpi_establishment_categories" USING "btree" ("establishment_id");



CREATE INDEX "idx_establishments_country" ON "public"."cpi_establishments" USING "btree" ("country_id");



CREATE INDEX "idx_finances_user" ON "public"."cpi_finances" USING "btree" ("user_id");



CREATE INDEX "idx_locations_country" ON "public"."cpi_locations" USING "btree" ("country_id");



CREATE INDEX "idx_prices_product_date" ON "public"."cpi_prices" USING "btree" ("product_id", "date" DESC);



CREATE INDEX "idx_prices_user" ON "public"."cpi_prices" USING "btree" ("user_id");



CREATE INDEX "idx_products_country_active" ON "public"."cpi_products" USING "btree" ("country_id", "is_active_product") INCLUDE ("product_name", "category_id");



CREATE INDEX "idx_real_cpi_country" ON "public"."cpi_real_cpi" USING "btree" ("country_id");



CREATE INDEX "idx_real_cpi_criterion" ON "public"."cpi_real_cpi" USING "btree" ("criterion_id");



CREATE INDEX "idx_tracking_country" ON "public"."cpi_tracking" USING "btree" ("country_id");



CREATE INDEX "idx_tracking_establishment" ON "public"."cpi_tracking" USING "btree" ("establishment_id");



CREATE INDEX "idx_tracking_product_fk" ON "public"."cpi_tracking" USING "btree" ("product_id");



CREATE INDEX "idx_volunteers_country" ON "public"."cpi_volunteers" USING "btree" ("country_id");



CREATE INDEX "idx_weights_category" ON "public"."cpi_weights" USING "btree" ("category_id");



CREATE INDEX "idx_weights_criterion" ON "public"."cpi_weights" USING "btree" ("criterion_id");



CREATE INDEX "idx_withdrawals_finance" ON "public"."cpi_withdrawals" USING "btree" ("finance_id");



ALTER TABLE ONLY "public"."cpi_annual_product_location_establishment_inflation"
    ADD CONSTRAINT "cpi_annual_product_location_establishment__recent_price_id_fkey" FOREIGN KEY ("recent_price_id") REFERENCES "public"."cpi_prices"("price_id");



ALTER TABLE ONLY "public"."cpi_annual_product_location_establishment_inflation"
    ADD CONSTRAINT "cpi_annual_product_location_establishment_establishment_id_fkey" FOREIGN KEY ("establishment_id") REFERENCES "public"."cpi_establishments"("establishment_id");



ALTER TABLE ONLY "public"."cpi_annual_product_location_establishment_inflation"
    ADD CONSTRAINT "cpi_annual_product_location_establishment_infl_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."cpi_locations"("location_id");



ALTER TABLE ONLY "public"."cpi_annual_product_location_establishment_inflation"
    ADD CONSTRAINT "cpi_annual_product_location_establishment_infla_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."cpi_countries"("country_id");



ALTER TABLE ONLY "public"."cpi_annual_product_location_establishment_inflation"
    ADD CONSTRAINT "cpi_annual_product_location_establishment_infla_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."cpi_products"("product_id");



ALTER TABLE ONLY "public"."cpi_categories"
    ADD CONSTRAINT "cpi_categories_branch_id_fkey" FOREIGN KEY ("branch_id") REFERENCES "public"."cpi_branches"("branch_id");



ALTER TABLE ONLY "public"."cpi_category_inflation"
    ADD CONSTRAINT "cpi_category_inflation_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."cpi_categories"("category_id");



ALTER TABLE ONLY "public"."cpi_category_inflation"
    ADD CONSTRAINT "cpi_category_inflation_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."cpi_countries"("country_id");



ALTER TABLE ONLY "public"."cpi_category_location_inflation"
    ADD CONSTRAINT "cpi_category_location_inflation_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."cpi_categories"("category_id");



ALTER TABLE ONLY "public"."cpi_category_location_inflation"
    ADD CONSTRAINT "cpi_category_location_inflation_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."cpi_countries"("country_id");



ALTER TABLE ONLY "public"."cpi_category_location_inflation"
    ADD CONSTRAINT "cpi_category_location_inflation_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."cpi_locations"("location_id");



ALTER TABLE ONLY "public"."cpi_establishment_categories"
    ADD CONSTRAINT "cpi_establishment_categories_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."cpi_categories"("category_id");



ALTER TABLE ONLY "public"."cpi_establishment_categories"
    ADD CONSTRAINT "cpi_establishment_categories_establishment_id_fkey" FOREIGN KEY ("establishment_id") REFERENCES "public"."cpi_establishments"("establishment_id");



ALTER TABLE ONLY "public"."cpi_establishments"
    ADD CONSTRAINT "cpi_establishments_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."cpi_countries"("country_id");



ALTER TABLE ONLY "public"."cpi_finances"
    ADD CONSTRAINT "cpi_finances_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."cpi_users"("user_id");



ALTER TABLE ONLY "public"."cpi_locations"
    ADD CONSTRAINT "cpi_locations_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."cpi_countries"("country_id");



ALTER TABLE ONLY "public"."cpi_prices"
    ADD CONSTRAINT "cpi_prices_establishment_id_fkey" FOREIGN KEY ("establishment_id") REFERENCES "public"."cpi_establishments"("establishment_id");



ALTER TABLE ONLY "public"."cpi_prices"
    ADD CONSTRAINT "cpi_prices_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."cpi_locations"("location_id");



ALTER TABLE ONLY "public"."cpi_prices"
    ADD CONSTRAINT "cpi_prices_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."cpi_products"("product_id");



ALTER TABLE ONLY "public"."cpi_prices"
    ADD CONSTRAINT "cpi_prices_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."cpi_users"("user_id");



ALTER TABLE ONLY "public"."cpi_products"
    ADD CONSTRAINT "cpi_products_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."cpi_categories"("category_id");



ALTER TABLE ONLY "public"."cpi_products"
    ADD CONSTRAINT "cpi_products_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."cpi_countries"("country_id");



ALTER TABLE ONLY "public"."cpi_real_cpi"
    ADD CONSTRAINT "cpi_real_cpi_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."cpi_countries"("country_id");



ALTER TABLE ONLY "public"."cpi_real_cpi"
    ADD CONSTRAINT "cpi_real_cpi_criterion_id_fkey" FOREIGN KEY ("criterion_id") REFERENCES "public"."cpi_criteria"("criterion_id");



ALTER TABLE ONLY "public"."cpi_tracking"
    ADD CONSTRAINT "cpi_tracking_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."cpi_countries"("country_id");



ALTER TABLE ONLY "public"."cpi_tracking"
    ADD CONSTRAINT "cpi_tracking_establishment_id_fkey" FOREIGN KEY ("establishment_id") REFERENCES "public"."cpi_establishments"("establishment_id");



ALTER TABLE ONLY "public"."cpi_tracking"
    ADD CONSTRAINT "cpi_tracking_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."cpi_locations"("location_id");



ALTER TABLE ONLY "public"."cpi_tracking"
    ADD CONSTRAINT "cpi_tracking_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."cpi_products"("product_id");



ALTER TABLE ONLY "public"."cpi_tracking"
    ADD CONSTRAINT "cpi_tracking_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."cpi_users"("user_id");



ALTER TABLE ONLY "public"."cpi_users"
    ADD CONSTRAINT "cpi_users_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cpi_volunteers"
    ADD CONSTRAINT "cpi_volunteers_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."cpi_countries"("country_id");



ALTER TABLE ONLY "public"."cpi_volunteers"
    ADD CONSTRAINT "cpi_volunteers_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cpi_weights"
    ADD CONSTRAINT "cpi_weights_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."cpi_categories"("category_id");



ALTER TABLE ONLY "public"."cpi_weights"
    ADD CONSTRAINT "cpi_weights_criterion_id_fkey" FOREIGN KEY ("criterion_id") REFERENCES "public"."cpi_criteria"("criterion_id");



ALTER TABLE ONLY "public"."cpi_withdrawals"
    ADD CONSTRAINT "cpi_withdrawals_finance_id_fkey" FOREIGN KEY ("finance_id") REFERENCES "public"."cpi_finances"("finance_id");



ALTER TABLE ONLY "public"."cpi_withdrawals"
    ADD CONSTRAINT "cpi_withdrawals_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."cpi_users"("user_id");



CREATE POLICY "Allow authenticated users to insert categories" ON "public"."cpi_categories" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow authenticated users to insert products" ON "public"."cpi_products" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow authenticated users to read branches" ON "public"."cpi_branches" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow public read access on categories" ON "public"."cpi_categories" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Allow public read access on countries" ON "public"."cpi_countries" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Allow public read access on establishments" ON "public"."cpi_establishments" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Allow public read access on prices" ON "public"."cpi_prices" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Allow public read access on products" ON "public"."cpi_products" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Allow public read access to cpi_criteria" ON "public"."cpi_criteria" FOR SELECT USING (true);



COMMENT ON POLICY "Allow public read access to cpi_criteria" ON "public"."cpi_criteria" IS 'Allows all users (authenticated and anonymous) to read criteria data. This is reference data needed by the application.';



CREATE POLICY "Allow public read access to cpi_locations" ON "public"."cpi_locations" FOR SELECT USING (true);



COMMENT ON POLICY "Allow public read access to cpi_locations" ON "public"."cpi_locations" IS 'Allows all users (authenticated and anonymous) to read location data. This is reference data needed by the application.';



CREATE POLICY "Enable read access for all users" ON "public"."cpi_criteria" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."cpi_locations" FOR SELECT USING (true);



CREATE POLICY "Public read access" ON "public"."cpi_annual_product_location_establishment_inflation" FOR SELECT USING (true);



CREATE POLICY "Public read access" ON "public"."cpi_category_inflation" FOR SELECT USING (true);



CREATE POLICY "Public read access" ON "public"."cpi_category_location_inflation" FOR SELECT USING (true);



CREATE POLICY "Public read access" ON "public"."cpi_establishment_categories" FOR SELECT USING (true);



CREATE POLICY "Public read access" ON "public"."cpi_real_cpi" FOR SELECT USING (true);



CREATE POLICY "Public read access" ON "public"."cpi_weights" FOR SELECT USING (true);



CREATE POLICY "Users can create their own withdrawals" ON "public"."cpi_withdrawals" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



COMMENT ON POLICY "Users can create their own withdrawals" ON "public"."cpi_withdrawals" IS 'Allows authenticated users to create withdrawal records for themselves. Optimized with SELECT auth.uid() for better performance.';



CREATE POLICY "Users can delete their own withdrawals" ON "public"."cpi_withdrawals" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



COMMENT ON POLICY "Users can delete their own withdrawals" ON "public"."cpi_withdrawals" IS 'Allows authenticated users to delete only their own withdrawal records. Optimized with SELECT auth.uid() for better performance.';



CREATE POLICY "Users can insert own withdrawals" ON "public"."cpi_withdrawals" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own finance records" ON "public"."cpi_finances" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can insert their own tracking" ON "public"."cpi_tracking" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can read their own finance records" ON "public"."cpi_finances" FOR SELECT TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can read their own tracking" ON "public"."cpi_tracking" FOR SELECT TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can read their own user record" ON "public"."cpi_users" FOR SELECT TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can read their own volunteer profile" ON "public"."cpi_volunteers" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update own withdrawals" ON "public"."cpi_withdrawals" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own tracking" ON "public"."cpi_tracking" FOR UPDATE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update their own volunteer profile" ON "public"."cpi_volunteers" FOR UPDATE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update their own withdrawals" ON "public"."cpi_withdrawals" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



COMMENT ON POLICY "Users can update their own withdrawals" ON "public"."cpi_withdrawals" IS 'Allows authenticated users to update only their own withdrawal records. Optimized with SELECT auth.uid() for better performance.';



CREATE POLICY "Users can view own withdrawals" ON "public"."cpi_withdrawals" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own withdrawals" ON "public"."cpi_withdrawals" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



COMMENT ON POLICY "Users can view their own withdrawals" ON "public"."cpi_withdrawals" IS 'Allows authenticated users to view only their own withdrawal records. Optimized with SELECT auth.uid() for better performance.';



ALTER TABLE "public"."cpi_annual_product_location_establishment_inflation" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_branches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_category_inflation" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_category_location_inflation" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_countries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_criteria" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_establishment_categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_establishments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_finances" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_locations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_prices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_products" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_real_cpi" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_tracking" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_volunteers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_weights" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cpi_withdrawals" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."add_product_and_price"("p_product_name" "text", "p_ean_code" "text", "p_country_id" bigint, "p_category_id" bigint, "p_establishment_id" bigint, "p_location_id" bigint, "p_price_value" numeric, "p_price_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."add_product_and_price"("p_product_name" "text", "p_ean_code" "text", "p_country_id" bigint, "p_category_id" bigint, "p_establishment_id" bigint, "p_location_id" bigint, "p_price_value" numeric, "p_price_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_product_and_price"("p_product_name" "text", "p_ean_code" "text", "p_country_id" bigint, "p_category_id" bigint, "p_establishment_id" bigint, "p_location_id" bigint, "p_price_value" numeric, "p_price_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_category"("p_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_category"("p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_category"("p_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."deactivate_product_tracking"("p_tracking_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."deactivate_product_tracking"("p_tracking_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."deactivate_product_tracking"("p_tracking_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_admin_dashboard_stats"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_admin_dashboard_stats"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_dashboard_stats"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_all_categories_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_all_categories_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_all_categories_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_all_establishments_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_all_establishments_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_all_establishments_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_available_products_for_tracking"("p_country_id" bigint, "p_location_id" bigint, "p_establishment_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."get_available_products_for_tracking"("p_country_id" bigint, "p_location_id" bigint, "p_establishment_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_available_products_for_tracking"("p_country_id" bigint, "p_location_id" bigint, "p_establishment_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_best_proxy_mx"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_best_proxy_mx"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_best_proxy_mx"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_finance_history"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_finance_history"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_finance_history"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_latest_prices_by_country"("p_country_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."get_latest_prices_by_country"("p_country_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_latest_prices_by_country"("p_country_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_pending_withdrawals"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_pending_withdrawals"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_pending_withdrawals"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_product_price_history"("p_tracking_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."get_product_price_history"("p_tracking_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_product_price_history"("p_tracking_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_products_needing_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_products_needing_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_products_needing_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_products_with_significant_changes"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_products_with_significant_changes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_products_with_significant_changes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_volunteer_dashboard"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_volunteer_dashboard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_volunteer_dashboard"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_volunteer_dashboard_stats"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_volunteer_dashboard_stats"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_volunteer_dashboard_stats"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_volunteer_finance_history"("p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_volunteer_finance_history"("p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_volunteer_finance_history"("p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_volunteers"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_volunteers"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_volunteers"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_volunteers_needing_reminders"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_volunteers_needing_reminders"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_volunteers_needing_reminders"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_withdrawal_history"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_withdrawal_history"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_withdrawal_history"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."process_withdrawal"("p_withdrawal_id" bigint, "p_status" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."process_withdrawal"("p_withdrawal_id" bigint, "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_withdrawal"("p_withdrawal_id" bigint, "p_status" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."recalculate_daily_cpi"() TO "anon";
GRANT ALL ON FUNCTION "public"."recalculate_daily_cpi"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalculate_daily_cpi"() TO "service_role";



GRANT ALL ON FUNCTION "public"."register_volunteer"("p_user_id" "uuid", "p_email" "text", "p_name" "text", "p_country_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."register_volunteer"("p_user_id" "uuid", "p_email" "text", "p_name" "text", "p_country_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_volunteer"("p_user_id" "uuid", "p_email" "text", "p_name" "text", "p_country_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."request_withdrawal"("p_amount" integer, "p_wallet_address" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."request_withdrawal"("p_amount" integer, "p_wallet_address" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."request_withdrawal"("p_amount" integer, "p_wallet_address" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."request_withdrawal"("p_amount" numeric, "p_polygon_address" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."request_withdrawal"("p_amount" numeric, "p_polygon_address" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."request_withdrawal"("p_amount" numeric, "p_polygon_address" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."stop_tracking_product"("p_tracking_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."stop_tracking_product"("p_tracking_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."stop_tracking_product"("p_tracking_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_product_price"("p_tracking_id" bigint, "p_price_value" numeric, "p_date" "date", "p_photo_url" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_product_price"("p_tracking_id" bigint, "p_price_value" numeric, "p_date" "date", "p_photo_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_product_price"("p_tracking_id" bigint, "p_price_value" numeric, "p_date" "date", "p_photo_url" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_product_price"("p_tracking_id" bigint, "p_price_value" numeric, "p_date" timestamp with time zone, "p_photo_url" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_product_price"("p_tracking_id" bigint, "p_price_value" numeric, "p_date" timestamp with time zone, "p_photo_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_product_price"("p_tracking_id" bigint, "p_price_value" numeric, "p_date" timestamp with time zone, "p_photo_url" "text") TO "service_role";



GRANT ALL ON TABLE "public"."cpi_annual_product_location_establishment_inflation" TO "anon";
GRANT ALL ON TABLE "public"."cpi_annual_product_location_establishment_inflation" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_annual_product_location_establishment_inflation" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_annual_product_location_establishment_aple_inflation_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_annual_product_location_establishment_aple_inflation_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_annual_product_location_establishment_aple_inflation_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_branches" TO "anon";
GRANT ALL ON TABLE "public"."cpi_branches" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_branches" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_branches_branch_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_branches_branch_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_branches_branch_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_categories" TO "anon";
GRANT ALL ON TABLE "public"."cpi_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_categories" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_categories_category_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_categories_category_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_categories_category_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_category_inflation" TO "anon";
GRANT ALL ON TABLE "public"."cpi_category_inflation" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_category_inflation" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_category_inflation_ci_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_category_inflation_ci_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_category_inflation_ci_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_category_location_inflation" TO "anon";
GRANT ALL ON TABLE "public"."cpi_category_location_inflation" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_category_location_inflation" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_category_location_inflation_cli_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_category_location_inflation_cli_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_category_location_inflation_cli_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_countries" TO "anon";
GRANT ALL ON TABLE "public"."cpi_countries" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_countries" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_countries_country_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_countries_country_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_countries_country_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_criteria" TO "anon";
GRANT ALL ON TABLE "public"."cpi_criteria" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_criteria" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_criteria_criterion_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_criteria_criterion_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_criteria_criterion_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_establishment_categories" TO "anon";
GRANT ALL ON TABLE "public"."cpi_establishment_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_establishment_categories" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_establishment_categories_establishment_category_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_establishment_categories_establishment_category_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_establishment_categories_establishment_category_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_establishments" TO "anon";
GRANT ALL ON TABLE "public"."cpi_establishments" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_establishments" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_establishments_establishment_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_establishments_establishment_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_establishments_establishment_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_finances" TO "anon";
GRANT ALL ON TABLE "public"."cpi_finances" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_finances" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_finances_finance_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_finances_finance_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_finances_finance_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_locations" TO "anon";
GRANT ALL ON TABLE "public"."cpi_locations" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_locations" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_locations_location_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_locations_location_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_locations_location_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_prices" TO "anon";
GRANT ALL ON TABLE "public"."cpi_prices" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_prices" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_prices_price_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_prices_price_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_prices_price_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_products" TO "anon";
GRANT ALL ON TABLE "public"."cpi_products" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_products" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_products_product_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_products_product_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_products_product_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_proxies" TO "anon";
GRANT ALL ON TABLE "public"."cpi_proxies" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_proxies" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_proxies_proxy_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_proxies_proxy_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_proxies_proxy_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_real_cpi" TO "anon";
GRANT ALL ON TABLE "public"."cpi_real_cpi" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_real_cpi" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_real_cpi_real_cpi_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_real_cpi_real_cpi_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_real_cpi_real_cpi_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_tracking" TO "anon";
GRANT ALL ON TABLE "public"."cpi_tracking" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_tracking" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_tracking_tracking_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_tracking_tracking_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_tracking_tracking_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_users" TO "anon";
GRANT ALL ON TABLE "public"."cpi_users" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_users" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_volunteers" TO "anon";
GRANT ALL ON TABLE "public"."cpi_volunteers" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_volunteers" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_weights" TO "anon";
GRANT ALL ON TABLE "public"."cpi_weights" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_weights" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_weights_weight_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_weights_weight_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_weights_weight_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cpi_withdrawals" TO "anon";
GRANT ALL ON TABLE "public"."cpi_withdrawals" TO "authenticated";
GRANT ALL ON TABLE "public"."cpi_withdrawals" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cpi_withdrawals_withdrawal_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cpi_withdrawals_withdrawal_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cpi_withdrawals_withdrawal_id_seq" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







