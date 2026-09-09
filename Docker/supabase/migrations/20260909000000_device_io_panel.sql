-- WROOM-1U I/O panel: per-sensor 1-Wire inventory (with user-assignable names)
-- plus a JSONB relay/custom-input state blob on embeddeds. Fed by the device's
-- /{company}/{device}/io MQTT snapshot via the mqtt-webhook edge function and
-- surfaced in the management UI's "Santé de l'appareil" tab.

-- ── 1-Wire sensors ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.device_sensors (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    embedded_id  uuid        NOT NULL REFERENCES public.embeddeds(id) ON DELETE CASCADE,
    bus          smallint    NOT NULL,                 -- 1 or 2 (J4 / J5-J6)
    rom          text        NOT NULL,                 -- 1-Wire ROM, hex, e.g. "F2000000CA146228"
    family       smallint    NOT NULL DEFAULT 0,       -- family code byte (40 = 0x28 = DS18B20)
    name         text,                                 -- user-assigned label (NULL = unnamed)
    last_celsius numeric(6,3),                          -- NULL if the device has no temperature reading
    last_seen    timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (embedded_id, rom)
);

COMMENT ON TABLE public.device_sensors IS '1-Wire sensors discovered on a WROOM-1U device, one row per ROM';
COMMENT ON COLUMN public.device_sensors.family IS '1-Wire family code (40 = DS18B20)';
COMMENT ON COLUMN public.device_sensors.name IS 'User-assigned label; never overwritten by device telemetry';

CREATE INDEX IF NOT EXISTS idx_device_sensors_embedded ON public.device_sensors (embedded_id, bus);

ALTER TABLE public.device_sensors ENABLE ROW LEVEL SECURITY;

GRANT SELECT, UPDATE ON public.device_sensors TO authenticated;
GRANT ALL ON public.device_sensors TO service_role;

-- Company-scoped read.
DROP POLICY IF EXISTS device_sensors_select ON public.device_sensors;
CREATE POLICY device_sensors_select ON public.device_sensors
    FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.embeddeds e
            WHERE e.id = device_sensors.embedded_id
              AND e.company = public.my_company_id()
        )
    );

-- Company-scoped update (the UI only ever changes `name`; other columns are
-- written by service_role from the mqtt-webhook).
DROP POLICY IF EXISTS device_sensors_update ON public.device_sensors;
CREATE POLICY device_sensors_update ON public.device_sensors
    FOR UPDATE TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.embeddeds e
            WHERE e.id = device_sensors.embedded_id
              AND e.company = public.my_company_id()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.embeddeds e
            WHERE e.id = device_sensors.embedded_id
              AND e.company = public.my_company_id()
        )
    );

DO $$
BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.device_sensors;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ── Relay + custom-input state on embeddeds ─────────────────────────────────
-- Shape: {"relays":[0,1],"inputs":[1,0,1],"updated_at":"2026-09-09T.."}
-- embeddeds already has replica identity full + realtime, so no extra plumbing.
ALTER TABLE public.embeddeds ADD COLUMN IF NOT EXISTS io_state jsonb;
COMMENT ON COLUMN public.embeddeds.io_state IS 'Latest WROOM-1U relay/custom-input snapshot from the /io MQTT topic';
