-- Store APNs bundle ID per subscription so debug and release tokens both work.
ALTER TABLE public.push_subscriptions
  ADD COLUMN IF NOT EXISTS apns_topic text;
