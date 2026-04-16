-- Add web flash columns to firmware_versions
ALTER TABLE firmware_versions ADD COLUMN IF NOT EXISTS is_public boolean NOT NULL DEFAULT true;
ALTER TABLE firmware_versions ADD COLUMN IF NOT EXISTS bootloader_path text;
ALTER TABLE firmware_versions ADD COLUMN IF NOT EXISTS partition_table_path text;

-- Allow anonymous users to read public firmware versions
GRANT SELECT ON public.firmware_versions TO anon;

-- Allow authenticated users to update firmware versions (for is_public toggle)
GRANT UPDATE ON public.firmware_versions TO authenticated;

-- RLS: anonymous can read public firmware
CREATE POLICY "Anyone can read public firmware versions"
  ON firmware_versions FOR SELECT TO anon
  USING (is_public = true);

-- RLS: admins can update their own company's firmware versions
CREATE POLICY "Admins can update own firmware versions"
  ON firmware_versions FOR UPDATE TO authenticated
  USING (company_id = my_company_id() AND i_am_admin())
  WITH CHECK (company_id = my_company_id() AND i_am_admin());
