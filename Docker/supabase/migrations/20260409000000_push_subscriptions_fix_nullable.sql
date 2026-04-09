-- Fix: p256dh and auth must be nullable for native (iOS/Android) push subscriptions.
-- The original migration (20260303) created them as NOT NULL for web push,
-- but the native migration (20260310) only made endpoint nullable.
-- Native registrations only provide fcm_token + platform, not web push keys.

ALTER TABLE public.push_subscriptions
  ALTER COLUMN p256dh DROP NOT NULL;

ALTER TABLE public.push_subscriptions
  ALTER COLUMN auth DROP NOT NULL;
