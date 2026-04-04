-- Device restart tracking: logs every ESP32 reboot with reason and prior uptime
-- to identify problematic devices and distinguish stable vs unstable ones.

CREATE TABLE IF NOT EXISTS public.device_restarts (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at       timestamptz NOT NULL DEFAULT now(),
    embedded_id      uuid        NOT NULL REFERENCES public.embeddeds(id) ON DELETE CASCADE,
    reason           text        NOT NULL,       -- mqtt_watchdog, ota, config, provision, factory_reset, power_on, panic, brownout, unknown
    uptime_sec       integer,                    -- seconds the device ran before this restart (NULL if unknown)
    firmware_version text,                       -- firmware version at time of restart
    hw_reason        text,                       -- ESP-IDF esp_reset_reason() string (SW_CPU_RESET, POWERON, etc.)
    raw              jsonb                       -- full original JSON payload for extensibility
);

COMMENT ON TABLE public.device_restarts IS 'Log of ESP32 device restarts with reason and prior uptime';
COMMENT ON COLUMN public.device_restarts.reason IS 'Software restart reason: mqtt_watchdog, ota, config, provision, factory_reset, power_on, panic, brownout, unknown';
COMMENT ON COLUMN public.device_restarts.uptime_sec IS 'How many seconds the device ran before this restart';
COMMENT ON COLUMN public.device_restarts.hw_reason IS 'Hardware reset reason from esp_reset_reason()';

CREATE INDEX idx_device_restarts_embedded_created
    ON public.device_restarts (embedded_id, created_at DESC);

ALTER TABLE public.device_restarts ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.device_restarts TO authenticated;
GRANT ALL ON public.device_restarts TO service_role;

CREATE POLICY device_restarts_select ON public.device_restarts
    FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.embeddeds e
            WHERE e.id = device_restarts.embedded_id
              AND e.company = public.my_company_id()
        )
    );

ALTER PUBLICATION supabase_realtime ADD TABLE public.device_restarts;

-- Extend embeddeds with latest restart info (avoids per-machine subquery on list page)
ALTER TABLE public.embeddeds ADD COLUMN last_restart_reason text;
ALTER TABLE public.embeddeds ADD COLUMN last_restart_at timestamptz;
