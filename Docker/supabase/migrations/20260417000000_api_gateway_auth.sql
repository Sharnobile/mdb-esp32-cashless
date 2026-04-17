-- Extend RLS helpers to support API-key JWTs (from api-v1 gateway).
-- CRITICAL: both functions stay LANGUAGE sql STABLE for RLS inlining.
-- See docs/superpowers/specs/2026-04-16-public-rest-api-design.md

-- 1. my_company_id() — add COALESCE fallback to api_company_id JWT claim
CREATE OR REPLACE FUNCTION my_company_id() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT company_id FROM organization_members WHERE user_id = auth.uid() LIMIT 1),
    (current_setting('request.jwt.claims', true)::json->>'api_company_id')::uuid
  )
$$;

-- 2. i_am_admin() — also recognise api_key_id JWT claim as admin
CREATE OR REPLACE FUNCTION i_am_admin() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT
    EXISTS (
      SELECT 1 FROM organization_members
      WHERE user_id = auth.uid() AND role = 'admin'
    )
    OR (current_setting('request.jwt.claims', true)::json->>'api_key_id') IS NOT NULL
$$;

-- 3. View hiding passkey from API consumers
CREATE OR REPLACE VIEW api_embeddeds AS
SELECT
  id, company, subdomain, mac_address, status, status_at,
  mdb_diagnostics, created_at, last_restart_reason,
  last_restart_at, online_since
FROM embeddeds;

-- 4. Grant view access to authenticated role (PostgREST needs this)
GRANT SELECT ON api_embeddeds TO authenticated;

-- 5. Configurable rate limit per API key (requests per minute)
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS rate_limit integer DEFAULT 100;
