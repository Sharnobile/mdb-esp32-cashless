import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// In-app account deletion (Apple Guideline 5.1.1(v)).
//
// Ordinary path: remove just the auth user (organization_members cascades).
// Sole-admin path: the company goes too, guarded by an exact company-name
// confirmation typed by the user.
//
// The ORDER of side effects is the design, not an implementation detail:
//   1. read product image paths (unreadable after the cascade)
//   2. delete_company_and_data() — one Postgres transaction
//   3. remove storage objects — only AFTER 2 succeeded; best-effort
//   4. auth.admin.deleteUser() — LAST, because GoTrue cannot join the Postgres
//      transaction. Failing between 2 and 4 leaves an org-less orphan admin who
//      can simply retry (a user with no company row is always deletable).
//      Reversing 2 and 4 would strand the company undeletable instead.
Deno.serve(async (req) => {
  const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { 'Content-Type': 'application/json' },
    })

  try {
    let confirmCompanyName: string | undefined
    try {
      const body = await req.json()
      confirmCompanyName =
        typeof body?.confirm_company_name === 'string'
          ? body.confirm_company_name
          : undefined
    } catch {
      // empty body is fine — the ordinary path needs none
    }

    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? ''
    const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
    if (userError || !user) {
      return json(401, { error: 'unauthorized' })
    }

    const { data: membership, error: memberError } = await adminClient
      .from('organization_members')
      .select('company_id, role')
      .eq('user_id', user.id)
      .maybeSingle()
    if (memberError) throw memberError

    let companyDeleted = false

    if (membership?.role === 'admin') {
      const { count: otherAdmins, error: countError } = await adminClient
        .from('organization_members')
        .select('user_id', { count: 'exact', head: true })
        .eq('company_id', membership.company_id)
        .eq('role', 'admin')
        .neq('user_id', user.id)
      if (countError) throw countError

      if ((otherAdmins ?? 0) === 0) {
        // Sole admin → the company goes with them (spec §4.1), name-guarded.
        const { data: company, error: companyError } = await adminClient
          .from('companies')
          .select('name')
          .eq('id', membership.company_id)
          .single()
        if (companyError) throw companyError

        if (confirmCompanyName !== company.name) {
          return json(400, { error: 'company_name_mismatch' })
        }

        // 1. Collect image paths BEFORE the cascade makes them unreadable.
        const { data: products, error: productsError } = await adminClient
          .from('products')
          .select('image_path')
          .eq('company', membership.company_id)
          .not('image_path', 'is', null)
        if (productsError) throw productsError
        const imagePaths = (products ?? [])
          .map((p) => p.image_path as string)
          .filter(Boolean)

        // 2. Atomic erasure (sales/paxcounter/stock_decrement_log/cash book
        //    explicitly, the rest via the now-fixed FK cascade).
        const { error: rpcError } = await adminClient.rpc(
          'delete_company_and_data',
          { p_company_id: membership.company_id }
        )
        if (rpcError) throw rpcError
        companyDeleted = true

        // 3. Storage cleanup — only after the RPC succeeded. Best-effort: a
        //    stale image after a completed deletion is the lesser harm, whereas
        //    removing images before a FAILING deletion would damage a live
        //    company for nothing.
        if (imagePaths.length > 0) {
          const { error: storageError } = await adminClient.storage
            .from('product-images')
            .remove(imagePaths)
          if (storageError) {
            console.error(
              `delete-account: company ${membership.company_id} deleted but ` +
                `${imagePaths.length} product images could not be removed: ` +
                storageError.message
            )
          }
        }
      }
      // Admin with another admin present → ordinary path: nothing company-side;
      // their organization_members row cascades from auth.users.
    }

    // 4. Last, and outside any transaction: the GoTrue account itself.
    const { error: deleteError } = await adminClient.auth.admin.deleteUser(user.id)
    if (deleteError) throw deleteError

    return json(200, { deleted: true, company_deleted: companyDeleted })
  } catch (err) {
    return json(500, { error: (err as Error)?.message ?? String(err) })
  }
})
