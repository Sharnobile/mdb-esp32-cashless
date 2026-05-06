-- =========================================================
-- Provider Settings
--
-- Per-company activation + config for extension-point providers
-- (deal-source, image-search, ai-backend, ...). One row per
-- (company, extension_point, provider_id). See
-- docs/superpowers/specs/2026-05-05-extension-provider-pattern-design.md
-- =========================================================

-- ─── A. Table ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.provider_settings (
  company_id      uuid        NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  extension_point text        NOT NULL,                   -- 'deal-source', 'image-search', ...
  provider_id     text        NOT NULL,                   -- 'marktguru' or 'webhook-{uuid}'
  enabled         boolean     NOT NULL DEFAULT false,
  config          jsonb       NOT NULL DEFAULT '{}'::jsonb,
  display_name    text,                                   -- user-facing for webhook providers
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (company_id, extension_point, provider_id)
);

-- Hot path: load all enabled providers for a (company, extension_point) pair.
CREATE INDEX IF NOT EXISTS idx_provider_settings_active
  ON public.provider_settings (company_id, extension_point)
  WHERE enabled = true;

-- ─── B. RLS ───────────────────────────────────────────────
ALTER TABLE public.provider_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS provider_settings_read  ON public.provider_settings;
DROP POLICY IF EXISTS provider_settings_write ON public.provider_settings;

CREATE POLICY provider_settings_read ON public.provider_settings
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

CREATE POLICY provider_settings_write ON public.provider_settings
  FOR ALL TO authenticated
  USING (company_id = public.my_company_id() AND public.i_am_admin())
  WITH CHECK (company_id = public.my_company_id() AND public.i_am_admin());

-- ─── C. Data: seed Marktguru for every deals-enabled company ──
-- Preserves existing behavior: companies that have deals_enabled = true today
-- get Marktguru auto-enabled as their first deal-source provider.
INSERT INTO public.provider_settings
  (company_id, extension_point, provider_id, enabled, config, display_name)
SELECT
  id,
  'deal-source',
  'marktguru',
  true,
  '{}'::jsonb,
  NULL
FROM public.companies
WHERE deals_enabled = true
ON CONFLICT (company_id, extension_point, provider_id) DO NOTHING;
