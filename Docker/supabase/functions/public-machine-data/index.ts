import { createClient } from '@supabase/supabase-js'

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
}

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
  const subdomainParam = url.searchParams.get('subdomain')

  if (!subdomainParam) {
    return jsonResponse({ error: 'subdomain parameter is required' }, 400)
  }

  const subdomain = parseInt(subdomainParam, 10)
  if (isNaN(subdomain)) {
    return jsonResponse({ error: 'subdomain must be an integer' }, 400)
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // 1. Find embedded device by subdomain
  const { data: embedded, error: embeddedErr } = await supabase
    .from('embeddeds')
    .select('id, status, status_at')
    .eq('subdomain', subdomain)
    .single()

  if (embeddedErr || !embedded) {
    return jsonResponse({ error: 'Machine not found' }, 404)
  }

  // 2. Find vending machine linked to this device
  const { data: machine, error: machineErr } = await supabase
    .from('vendingMachine')
    .select('id, name, location_lat, location_lon')
    .eq('embedded', embedded.id)
    .single()

  if (machineErr || !machine) {
    return jsonResponse({ error: 'Machine not found' }, 404)
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

  return jsonResponse({
    machine: {
      name: machine.name,
      location_lat: machine.location_lat,
      location_lon: machine.location_lon,
    },
    machine_id: machine.id,
    status: embedded.status,
    status_at: embedded.status_at,
    categories,
  })
})
