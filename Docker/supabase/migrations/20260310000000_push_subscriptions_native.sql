-- Add native push notification support (FCM/APNs via Capacitor)
-- Existing web subscriptions continue to work unchanged (DEFAULT 'web').

-- Platform discriminator: web (existing), android, ios
ALTER TABLE public.push_subscriptions
  ADD COLUMN IF NOT EXISTS platform text NOT NULL DEFAULT 'web'
    CHECK (platform IN ('web', 'android', 'ios'));

-- FCM registration token for native apps
ALTER TABLE public.push_subscriptions
  ADD COLUMN IF NOT EXISTS fcm_token text;

-- Native subscriptions don't have web push fields
ALTER TABLE public.push_subscriptions
  ALTER COLUMN endpoint DROP NOT NULL;

-- Prevent duplicate FCM tokens per user
CREATE UNIQUE INDEX IF NOT EXISTS push_subscriptions_fcm_token_unique
  ON public.push_subscriptions (user_id, fcm_token)
  WHERE fcm_token IS NOT NULL;
