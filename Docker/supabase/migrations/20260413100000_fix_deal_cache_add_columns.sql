-- =========================================================
-- Fix: add missing columns to deal_cache
--
-- The initial migration 20260413000000 was amended after
-- some installs already applied it. This migration adds
-- the columns idempotently so both fresh and existing
-- databases converge to the same schema.
-- =========================================================

ALTER TABLE public.deal_cache
  ADD COLUMN IF NOT EXISTS image_url_large text;

ALTER TABLE public.deal_cache
  ADD COLUMN IF NOT EXISTS external_url text;

ALTER TABLE public.deal_cache
  ADD COLUMN IF NOT EXISTS matched_tokens text[];
