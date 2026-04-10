-- Add public_listing flag for discovery view opt-out
ALTER TABLE public."vendingMachine"
  ADD COLUMN IF NOT EXISTS public_listing BOOLEAN NOT NULL DEFAULT true;

COMMENT ON COLUMN public."vendingMachine".public_listing IS
  'Whether this machine appears in public discovery views (/m/ global map, /m/o/[company] operator page). Direct URL /m/[id] always works regardless.';
