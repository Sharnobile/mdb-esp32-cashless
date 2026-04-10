import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  })
}

interface MachineRow {
  id: string
  name: string | null
  location_lat: number | null
  location_lon: number | null
  companies: { name: string | null } | null
  embeddeds: { status: string | null } | null
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS })
  }

  if (req.method !== 'GET') {
    return jsonResponse({ error: 'Method not allowed' }, 405)
  }

  const url = new URL(req.url)
  const companyId = url.searchParams.get('company_id')

  if (companyId && !UUID_RE.test(companyId)) {
    return jsonResponse({ error: 'company_id must be a valid UUID' }, 400)
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // If filtering by company_id, verify the company exists and get its name
  let companyObject: { name: string | null } | null = null
  if (companyId) {
    const { data: company, error: companyError } = await supabase
      .from('companies')
      .select('id, name')
      .eq('id', companyId)
      .maybeSingle()

    if (companyError || !company) {
      return jsonResponse({ error: 'Operator not found' }, 404)
    }
    companyObject = { name: company.name }
  }

  // Build machine query
  let query = supabase
    .from('vendingMachine')
    .select(`
      id,
      name,
      location_lat,
      location_lon,
      companies!vendingMachine_company_fkey(name),
      embeddeds!vendingMachine_embedded_fkey(status)
    `)
    .eq('public_listing', true)
    .order('name', { ascending: true })

  if (companyId) {
    query = query.eq('company', companyId)
  }

  const { data, error } = await query

  if (error) {
    console.error('Failed to fetch public machines:', error)
    return jsonResponse({ error: 'Failed to fetch machines' }, 500)
  }

  const machines = (data as unknown as MachineRow[] || []).map((m) => ({
    id: m.id,
    name: m.name,
    location_lat: m.location_lat,
    location_lon: m.location_lon,
    company_name: m.companies?.name ?? null,
    status: m.embeddeds?.status ?? null,
  }))

  const response: Record<string, unknown> = { machines }
  if (companyObject) {
    response.company = companyObject
  }

  return jsonResponse(response)
})
