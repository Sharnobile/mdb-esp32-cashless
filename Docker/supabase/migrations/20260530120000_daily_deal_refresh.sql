-- Daily deal refresh + new-deal detection.
-- Spec: docs/superpowers/specs/2026-05-30-daily-deal-refresh-new-deals-design.md
--
-- Adds:
--   1. companies.deals_refresh_hour  – opt-in daily refresh hour (NULL = off)
--   2. deal_offer_first_seen         – persistent first-seen stamp per offer
--                                      (survives the deal_cache DELETE+INSERT rewrite)
--   3. deal_user_seen                – per-user baseline so rollout has no day-1 backlog
--   4. get_new_deal_keys / count     – "new/unhandled" offers for the current user
--   5. dispatch_deal_refresh + cron  – hourly dispatcher, fires deal-search per company
--
-- "New/unhandled" = offer currently in deal_cache, still valid, first seen after the
-- user's baseline, and not yet pinned or archived by that user (inbox model).
--
-- The cron scheduling is guarded so the migration applies cleanly where pg_cron is
-- not in shared_preload_libraries (local `supabase start`): the function + columns
-- are still created; only the schedule is skipped (with a NOTICE).

-- 1. Column on companies -----------------------------------------------------
ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS deals_refresh_hour smallint
    CHECK (deals_refresh_hour IS NULL
           OR (deals_refresh_hour BETWEEN 0 AND 23));

COMMENT ON COLUMN public.companies.deals_refresh_hour IS
  'Hour-of-day (0..23, local time per companies.timezone) at which the daily deal refresh fires. NULL = disabled. Requires deals_enabled = true.';

-- 2. Persistent first-seen stamp per offer -----------------------------------
-- Keyed by (company_id, retailer, offer_id) — the stable external identity of an
-- offer — because deal_cache rows are wiped + rewritten on every refresh, so
-- deal_cache.created_at cannot tell us what is new.
CREATE TABLE IF NOT EXISTS public.deal_offer_first_seen (
  company_id    uuid        NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  retailer      text        NOT NULL,
  offer_id      text        NOT NULL,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (company_id, retailer, offer_id)
);

ALTER TABLE public.deal_offer_first_seen ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.deal_offer_first_seen TO authenticated;
GRANT ALL    ON public.deal_offer_first_seen TO service_role;

-- Company members may read; writes happen only via the service-role client in the
-- deal-search edge function (which bypasses RLS), so no authenticated write policy.
DROP POLICY IF EXISTS "deal_offer_first_seen_select" ON public.deal_offer_first_seen;
CREATE POLICY "deal_offer_first_seen_select" ON public.deal_offer_first_seen
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

-- 3. Per-user baseline -------------------------------------------------------
-- baseline_at marks "start counting new deals from here" for a user. Created
-- lazily (default now()) by get_new_deal_keys() the first time it runs for the
-- user, so existing offers are never retroactively flagged "new".
CREATE TABLE IF NOT EXISTS public.deal_user_seen (
  user_id     uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  company_id  uuid        NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  baseline_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, company_id)
);

ALTER TABLE public.deal_user_seen ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.deal_user_seen TO authenticated;
GRANT ALL    ON public.deal_user_seen TO service_role;

-- Read-only for the owner. The baseline row is written only by the SECURITY
-- DEFINER RPC below (bypasses RLS), so no authenticated INSERT/UPDATE policy.
DROP POLICY IF EXISTS "deal_user_seen_select" ON public.deal_user_seen;
CREATE POLICY "deal_user_seen_select" ON public.deal_user_seen
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() AND company_id = public.my_company_id());

-- 4. Backfill first-seen for offers already in the cache ---------------------
-- Existing offers get first_seen_at = now(); combined with the per-user baseline
-- (also now() on first access) this means no day-1 backlog of "new" deals.
INSERT INTO public.deal_offer_first_seen (company_id, retailer, offer_id)
SELECT DISTINCT company_id, retailer, offer_id
FROM public.deal_cache
WHERE retailer IS NOT NULL AND offer_id IS NOT NULL
ON CONFLICT (company_id, retailer, offer_id) DO NOTHING;

-- 5. RPC: new/unhandled offer keys for the current user ----------------------
CREATE OR REPLACE FUNCTION public.get_new_deal_keys()
RETURNS TABLE (retailer text, offer_id text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_company  uuid := public.my_company_id();
  v_user     uuid := auth.uid();
  v_baseline timestamptz;
BEGIN
  IF v_company IS NULL OR v_user IS NULL THEN
    RETURN;
  END IF;

  -- Lazy baseline (ON CONFLICT DO NOTHING so concurrent dashboard + deals loads
  -- never race), then read it back.
  INSERT INTO public.deal_user_seen (user_id, company_id)
  VALUES (v_user, v_company)
  ON CONFLICT (user_id, company_id) DO NOTHING;

  SELECT dus.baseline_at INTO v_baseline
  FROM public.deal_user_seen dus
  WHERE dus.user_id = v_user AND dus.company_id = v_company;

  RETURN QUERY
  SELECT DISTINCT dc.retailer, dc.offer_id
  FROM public.deal_cache dc
  JOIN public.deal_offer_first_seen fs
    ON  fs.company_id = dc.company_id
    AND fs.retailer   = dc.retailer
    AND fs.offer_id   = dc.offer_id
  WHERE dc.company_id = v_company
    AND dc.offer_id IS NOT NULL
    AND (dc.valid_until IS NULL OR dc.valid_until >= current_date)
    AND fs.first_seen_at > v_baseline
    AND NOT EXISTS (
      SELECT 1 FROM public.deal_user_state us
      WHERE us.user_id    = v_user
        AND us.company_id  = v_company
        AND us.retailer    = dc.retailer
        AND us.offer_id    = dc.offer_id
        AND (us.pinned_at IS NOT NULL OR us.archived_at IS NOT NULL)
    );
END $$;

COMMENT ON FUNCTION public.get_new_deal_keys IS
  'Returns (retailer, offer_id) of offers that are new/unhandled for the calling user: currently cached, valid, first seen after the user baseline, and not yet pinned/archived. Lazily creates the user baseline on first call.';

-- 6. RPC: count of new/unhandled offers (dashboard banner) -------------------
CREATE OR REPLACE FUNCTION public.get_new_deals_count()
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT count(*)::int FROM public.get_new_deal_keys();
$$;

COMMENT ON FUNCTION public.get_new_deals_count IS
  'Count of new/unhandled deals for the calling user. Wraps get_new_deal_keys().';

GRANT EXECUTE ON FUNCTION public.get_new_deal_keys()   TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_new_deals_count() TO authenticated;

-- 7. Extensions (already created by the low-stock migration; idempotent) ------
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- 8. Dispatcher --------------------------------------------------------------
-- Mirrors dispatch_low_stock_pushes. Additionally gates on deals_enabled (a
-- company with deals off must never be auto-refreshed) — a deliberate divergence
-- from the low-stock dispatcher, which keys only on its hour column.
CREATE OR REPLACE FUNCTION public.dispatch_deal_refresh()
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
    RAISE WARNING 'dispatch_deal_refresh: app.settings.supabase_url or service_role_key not set; skipping. Run Docker/update.sh to configure.';
    RETURN;
  END IF;

  FOR v_company IN
    SELECT id
    FROM public.companies
    WHERE deals_enabled = true
      AND deals_refresh_hour IS NOT NULL
      AND deals_refresh_hour
          = EXTRACT(HOUR FROM (now() AT TIME ZONE timezone))::smallint
  LOOP
    PERFORM net.http_post(
      url     := v_url || '/functions/v1/deal-search',
      headers := jsonb_build_object(
                   'Authorization', 'Bearer ' || v_key,
                   'Content-Type',  'application/json'),
      body    := jsonb_build_object('company_id', v_company.id, 'scheduled', true)
    );
  END LOOP;
END $$;

COMMENT ON FUNCTION public.dispatch_deal_refresh IS
  'Called hourly by pg_cron. Selects deals-enabled companies whose configured local-time hour matches now, and POSTs deal-search (scheduled mode) per company. Reads supabase_url and service_role_key from app.settings.* (set by Docker/setup.sh / Docker/update.sh).';

-- 9. Cron schedule (guarded for environments without pg_cron) ----------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'deal_daily_refresh') THEN
      PERFORM cron.unschedule('deal_daily_refresh');
    END IF;

    PERFORM cron.schedule(
      'deal_daily_refresh',
      '0 * * * *',
      $cron$SELECT public.dispatch_deal_refresh();$cron$
    );

    RAISE NOTICE 'deal_daily_refresh: scheduled hourly';
  ELSE
    RAISE WARNING 'pg_cron not installed; deal_daily_refresh not scheduled. Fix shared_preload_libraries and re-run migration, or invoke dispatch_deal_refresh() manually.';
  END IF;
END $$;
