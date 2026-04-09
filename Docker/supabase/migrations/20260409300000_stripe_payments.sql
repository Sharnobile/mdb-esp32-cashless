-- Stripe payment integration: per-company keys + payments table

-- 1. Add Stripe columns to companies (same pattern as anthropic_api_key)
ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS stripe_secret_key TEXT,
  ADD COLUMN IF NOT EXISTS stripe_publishable_key TEXT,
  ADD COLUMN IF NOT EXISTS stripe_webhook_secret TEXT;

-- 2. Payments table (records all Stripe payments for audit + idempotency)
CREATE TABLE public.payments (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  stripe_payment_intent_id TEXT NOT NULL UNIQUE,
  company_id               UUID NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  machine_id               UUID NOT NULL REFERENCES public."vendingMachine"(id) ON DELETE CASCADE,
  embedded_id              UUID REFERENCES public.embeddeds(id) ON DELETE SET NULL,
  product_name             TEXT NOT NULL,
  slot                     INTEGER NOT NULL,
  amount_cents             INTEGER NOT NULL,
  currency                 TEXT NOT NULL DEFAULT 'eur',
  status                   TEXT NOT NULL DEFAULT 'succeeded' CHECK (status IN ('succeeded', 'failed', 'refunded')),
  credit_delivered         BOOLEAN NOT NULL DEFAULT false,
  credit_delivered_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_payments_company_created
  ON public.payments (company_id, created_at DESC);

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

-- Operators can view their company's payments
CREATE POLICY "payments_select" ON public.payments
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());
