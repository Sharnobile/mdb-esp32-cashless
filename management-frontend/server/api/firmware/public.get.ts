import { defineEventHandler } from 'h3'

export default defineEventHandler(async (event) => {
  const supabase = useServerSupabaseAnon(event)

  const { data, error } = await supabase
    .from('firmware_versions')
    .select('id, version_label, notes, created_at, bootloader_path, partition_table_path')
    .eq('is_public', true)
    .order('created_at', { ascending: false })

  if (error) {
    throw createError({ statusCode: 500, statusMessage: 'Failed to fetch firmware versions' })
  }

  return (data ?? []).map((fw: Record<string, unknown>) => ({
    id: fw.id,
    version_label: fw.version_label,
    notes: fw.notes,
    created_at: fw.created_at,
    has_full_flash: Boolean(fw.bootloader_path && fw.partition_table_path),
  }))
})
