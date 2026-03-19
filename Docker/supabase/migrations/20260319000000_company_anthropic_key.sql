-- Add per-company Anthropic API key for AI insights feature
ALTER TABLE public.companies ADD COLUMN anthropic_api_key TEXT;

-- Grant UPDATE permission to authenticated role (was missing — only SELECT and INSERT existed)
GRANT UPDATE ON public.companies TO authenticated;

-- Allow admins to update their own company row (e.g. to set API key in settings)
CREATE POLICY "companies_update_admin" ON public.companies
  FOR UPDATE TO authenticated
  USING (id = public.my_company_id() AND public.i_am_admin())
  WITH CHECK (id = public.my_company_id() AND public.i_am_admin());
