-- Fix infinite RLS recursion introduced by 20260417000000_api_gateway_auth.sql.
--
-- That migration did CREATE OR REPLACE FUNCTION without SECURITY DEFINER, which
-- silently reset both helpers to the default SECURITY INVOKER. Because
-- my_company_id() reads from organization_members, and the RLS policy on
-- organization_members calls my_company_id(), the helper now recurses inside
-- any RLS-gated query -> PostgreSQL 54001 (stack depth limit exceeded).
--
-- 20260228140000_fix_rls_recursion.sql originally set these to SECURITY DEFINER
-- for exactly this reason. Restore that while keeping the new COALESCE / OR
-- branches for the api-v1 gateway's api_company_id / api_key_id JWT claims.

CREATE OR REPLACE FUNCTION public.my_company_id() RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT COALESCE(
    (SELECT company_id FROM public.organization_members WHERE user_id = auth.uid() LIMIT 1),
    (current_setting('request.jwt.claims', true)::json->>'api_company_id')::uuid
  )
$$;

CREATE OR REPLACE FUNCTION public.i_am_admin() RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT
    EXISTS (
      SELECT 1 FROM public.organization_members
      WHERE user_id = auth.uid() AND role = 'admin'
    )
    OR (current_setting('request.jwt.claims', true)::json->>'api_key_id') IS NOT NULL
$$;
