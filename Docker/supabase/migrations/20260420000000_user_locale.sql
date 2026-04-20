-- Per-user notification locale. Default 'en' matches prior behavior byte-for-byte.
-- CHECK keeps the column closed to en/de until a future migration opens it wider.
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS locale text NOT NULL DEFAULT 'en';

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_locale_check;

ALTER TABLE public.users
  ADD CONSTRAINT users_locale_check CHECK (locale IN ('en', 'de'));
