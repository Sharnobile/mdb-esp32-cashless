-- Widen users.locale to allow 'nl', per the note left in 20260420000000_user_locale.sql.
-- Applied after 20260713000000_user_locale_add_fr.sql, so the set stays additive.
ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_locale_check;

ALTER TABLE public.users
  ADD CONSTRAINT users_locale_check CHECK (locale IN ('en', 'de', 'fr', 'nl'));
