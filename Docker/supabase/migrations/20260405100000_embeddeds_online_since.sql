-- Add online_since to track actual device boot time (for uptime calculation).
-- status_at is updated on every mdb-log heartbeat (every 5min) so it cannot
-- be used for uptime. online_since is only set when status = 'online'.
ALTER TABLE public.embeddeds ADD COLUMN online_since timestamptz;

COMMENT ON COLUMN public.embeddeds.online_since IS 'Timestamp when device last came online (set only on status=online). Use for uptime calculation.';
