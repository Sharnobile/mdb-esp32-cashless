-- Capture production schema drift: public.users.username exists on production
-- but was never added via a migration (discovered 2026-05-31 while building the
-- prod->dev data sync, which COPYs prod's public.users into a dev DB that lacked
-- the column). This idempotent migration brings dev and any other environment in
-- line with production; it is a no-op on production (the column already exists).
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS username text;
