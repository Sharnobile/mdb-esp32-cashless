-- Low-stock daily push via pg_cron.
-- Spec: docs/superpowers/specs/2026-05-28-low-stock-daily-push-design.md
--
-- Adds two opt-in columns to `companies`, creates pg_cron + pg_net,
-- creates a dispatcher SECURITY DEFINER function, and schedules a
-- global hourly cron job that fires the dispatcher.
--
-- The cron scheduling is guarded so the migration applies cleanly on
-- environments where pg_cron is not in shared_preload_libraries
-- (local `supabase start` dev). On such environments the dispatcher
-- function and columns are still created; only the schedule itself is
-- skipped (with a NOTICE).

-- 1. Columns on companies ----------------------------------------------------
ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS timezone text NOT NULL DEFAULT 'Europe/Berlin';

ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS low_stock_notification_hour smallint
    CHECK (low_stock_notification_hour IS NULL
           OR (low_stock_notification_hour BETWEEN 0 AND 23));

COMMENT ON COLUMN public.companies.timezone IS
  'IANA timezone name used for low_stock_notification_hour. Default Europe/Berlin.';
COMMENT ON COLUMN public.companies.low_stock_notification_hour IS
  'Hour-of-day (0..23, local time per timezone) at which the daily low-stock push fires. NULL = disabled.';

-- 2. Extensions --------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- 3. Dispatcher function -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.dispatch_low_stock_pushes()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_company record;
  v_url text := current_setting('app.settings.supabase_url', true);
  v_key text := current_setting('app.settings.service_role_key', true);
BEGIN
  IF v_url IS NULL OR v_url = '' OR v_key IS NULL OR v_key = '' THEN
    RAISE WARNING 'dispatch_low_stock_pushes: app.settings.supabase_url or service_role_key not set; skipping. Run Docker/update.sh to configure.';
    RETURN;
  END IF;

  FOR v_company IN
    SELECT id
    FROM public.companies
    WHERE low_stock_notification_hour IS NOT NULL
      AND low_stock_notification_hour
          = EXTRACT(HOUR FROM (now() AT TIME ZONE timezone))::smallint
  LOOP
    PERFORM net.http_post(
      url     := v_url || '/functions/v1/check-low-stock',
      headers := jsonb_build_object(
                   'Authorization', 'Bearer ' || v_key,
                   'Content-Type',  'application/json'),
      body    := jsonb_build_object('company_id', v_company.id)
    );
  END LOOP;
END $$;

COMMENT ON FUNCTION public.dispatch_low_stock_pushes IS
  'Called hourly by pg_cron. Selects companies whose configured local-time hour matches now, and POSTs check-low-stock per company. Reads supabase_url and service_role_key from app.settings.* (set by Docker/setup.sh / Docker/update.sh).';

-- 4. Cron schedule (guarded for environments without pg_cron) ----------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- Idempotent unschedule of any previous version
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'low_stock_daily_push') THEN
      PERFORM cron.unschedule('low_stock_daily_push');
    END IF;

    PERFORM cron.schedule(
      'low_stock_daily_push',
      '0 * * * *',
      $cron$SELECT public.dispatch_low_stock_pushes();$cron$
    );

    RAISE NOTICE 'low_stock_daily_push: scheduled hourly';
  ELSE
    RAISE WARNING 'pg_cron not installed; low_stock_daily_push not scheduled. Fix shared_preload_libraries and re-run migration, or invoke dispatch_low_stock_pushes() manually.';
  END IF;
END $$;
