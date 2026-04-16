import { defineEventHandler, getQuery, createError } from 'h3'

export default defineEventHandler(async (event) => {
  const query = getQuery(event)
  const id = query.id as string

  if (!id) {
    throw createError({ statusCode: 400, statusMessage: 'Missing firmware version id' })
  }

  const supabase = useServerSupabaseAnon(event)
  const config = useRuntimeConfig(event)
  const supabaseUrl = config.public.supabase?.url || process.env.SUPABASE_URL || ''

  const { data: fw, error } = await supabase
    .from('firmware_versions')
    .select('id, version_label, file_path, bootloader_path, partition_table_path')
    .eq('id', id)
    .eq('is_public', true)
    .maybeSingle()

  if (error || !fw) {
    throw createError({ statusCode: 404, statusMessage: 'Firmware version not found' })
  }

  function storageUrl(path: string): string {
    return `${supabaseUrl}/storage/v1/object/public/firmware/${path}`
  }

  const parts: { path: string; offset: number }[] = []

  if (fw.bootloader_path) {
    parts.push({ path: storageUrl(fw.bootloader_path), offset: 0 })
  }
  if (fw.partition_table_path) {
    parts.push({ path: storageUrl(fw.partition_table_path), offset: 0x8000 })
  }
  parts.push({ path: storageUrl(fw.file_path), offset: 0x20000 })

  return {
    name: 'VMflow MDB Cashless',
    version: fw.version_label,
    builds: [
      {
        chipFamily: 'ESP32-S3',
        parts,
      },
    ],
  }
})
