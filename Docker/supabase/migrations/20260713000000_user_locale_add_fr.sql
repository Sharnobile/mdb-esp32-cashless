-- Widen users.locale to allow 'fr', per the note left in 20260420000000_user_locale.sql.
ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_locale_check;

ALTER TABLE public.users
  ADD CONSTRAINT users_locale_check CHECK (locale IN ('en', 'de', 'fr'));
