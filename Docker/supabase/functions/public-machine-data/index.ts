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

interface TrayRow {
  item_number: number
  capacity: number
  current_stock: number
  product_id: string
  products: {
    id: string
    name: string
    sellprice: number | null
    image_path: string | null
    discontinued: boolean
    product_category: { name: string } | null
  } | null
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS })
  }

  if (req.method !== 'GET') {
    return jsonResponse({ error: 'Method not allowed' }, 405)
  }

  const url = new URL(req.url)
  const machineId = url.searchParams.get('id')

  if (!machineId) {
    return jsonResponse({ error: 'id parameter is required' }, 400)
  }

  if (!UUID_RE.test(machineId)) {
    return jsonResponse({ error: 'id must be a valid UUID' }, 400)
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // 1. Find vending machine by UUID
  const { data: machine, error: machineErr } = await supabase
    .from('vendingMachine')
    .select('id, name, location_lat, location_lon, company, embedded')
    .eq('id', machineId)
    .single()

  if (machineErr || !machine) {
    return jsonResponse({ error: 'Machine not found' }, 404)
  }

  // 2. Optionally fetch embedded device info (for online status)
  let status: string | null = null
  let statusAt: string | null = null
  if (machine.embedded) {
    const { data: embedded } = await supabase
      .from('embeddeds')
      .select('status, status_at')
      .eq('id', machine.embedded)
      .single()
    if (embedded) {
      status = embedded.status
      statusAt = embedded.status_at
    }
  }

  // 3. Fetch trays with products and categories
  const { data: trays } = await supabase
    .from('machine_trays')
    .select('item_number, capacity, current_stock, product_id, products(id, name, sellprice, image_path, discontinued, product_category(name))')
    .eq('machine_id', machine.id)
    .not('product_id', 'is', null)
    .order('item_number')

  // 4. Group by category, filter out discontinued
  const categoryMap = new Map<string, Array<{
    id: string
    name: string
    slot: number
    price: number | null
    stock: number
    capacity: number
    image_path: string | null
    available: boolean
  }>>()

  for (const tray of (trays as unknown as TrayRow[]) || []) {
    const product = tray.products
    if (!product || product.discontinued) continue

    const categoryName = product.product_category?.name || 'Sonstige'

    if (!categoryMap.has(categoryName)) {
      categoryMap.set(categoryName, [])
    }

    categoryMap.get(categoryName)!.push({
      id: product.id,
      name: product.name,
      slot: tray.item_number,
      price: product.sellprice,
      stock: tray.current_stock,
      capacity: tray.capacity,
      image_path: product.image_path,
      available: tray.current_stock > 0,
    })
  }

  const categories = Array.from(categoryMap.entries()).map(([name, products]) => ({
    name,
    products,
  }))

  // 5. Fetch company info (name + Stripe check + imprint / Betreiberinformationen)
  const { data: company } = await supabase
    .from('companies')
    .select(
      'name, stripe_publishable_key, legal_name, contact_email, contact_phone, website, address_street, address_house_number, address_postal_code, address_city, country_code',
    )
    .eq('id', machine.company)
    .single()

  // Build imprint object for the public storefront. Any non-null field is
  // surfaced to the UI; the client decides whether to show the "Betreiber-
  // informationen" button at all (all fields null → no imprint data yet).
  const imprint = company
    ? {
        legal_name:          company.legal_name ?? null,
        contact_email:       company.contact_email ?? null,
        contact_phone:       company.contact_phone ?? null,
        website:             company.website ?? null,
        address_street:      company.address_street ?? null,
        address_house_number: company.address_house_number ?? null,
        address_postal_code: company.address_postal_code ?? null,
        address_city:        company.address_city ?? null,
        country_code:        company.country_code ?? null,
      }
    : null

  return jsonResponse({
    machine: {
      name: machine.name,
      location_lat: machine.location_lat,
      location_lon: machine.location_lon,
    },
    machine_id: machine.id,
    company_id: machine.company,
    company_name: company?.name ?? null,
    imprint,
    status,
    status_at: statusAt,
    categories,
    payment_enabled: !!company?.stripe_publishable_key,
  })
})
