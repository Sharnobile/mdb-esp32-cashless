-- Add velocity_days setting to companies (default 30 days)
-- Used for stock range calculation on the warehouse page.
ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS velocity_days integer NOT NULL DEFAULT 30;
