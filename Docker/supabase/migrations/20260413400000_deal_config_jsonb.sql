-- =========================================================
-- Configurable deal search keywords per company
--
-- Stores matching keywords (generic terms, wildcard phrases,
-- app detection patterns, retailer prospekt URLs) as jsonb
-- so they can be customised per company in settings.
--
-- The edge function reads these and falls back to built-in
-- country-based defaults when null.
-- =========================================================

ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS deals_config jsonb;

-- deals_config schema:
-- {
--   "generic_terms": ["verschiedene", "sorten", ...],
--   "wildcard_phrases": ["verschiedene", "versch", "diverse", ...],
--   "app_detection_patterns": ["mit app", "netto-app", ...],
--   "retailer_prospekt_urls": { "lidl": "https://...", ... }
-- }
-- All keys are optional — null/missing = use country default.
