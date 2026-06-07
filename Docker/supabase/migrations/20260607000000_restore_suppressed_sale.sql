-- =========================================================
-- Restore a suppressed (auto-removed) sale as a real sale
--
-- Inverse of the brownout-suppression feature (20260602130000): an admin
-- promotes a suppressed_sales row back into a real public.sales row when the
-- auto-suppression was wrong (the sale was genuinely distinct).
--
-- The BEFORE-INSERT trigger stamp_machine_and_decrement_stock() resolves
-- machine_id from embedded_id, applies the tax snapshot, decrements tray
-- stock by 1, and stamps product_id from the CURRENT tray. We then override
-- product_id with the immutable suppression-time snapshot so the restored
-- sale shows exactly what the "auto-removed duplicates" list showed, even if
-- the tray's product changed since.
--
-- Atomic (one function body = one transaction): insert + product override +
-- delete suppressed row + audit either all succeed or all roll back.
--
-- Admin-only + company-scoped, mirroring delete_sale_and_restore_stock /
-- insert_manual_sale. SECURITY DEFINER + SET search_path = '' with every
-- identifier schema-qualified. Idempotent (CREATE OR REPLACE + explicit
-- GRANT) so safe to re-run via update.sh. Additive / backward-compatible.
-- =========================================================

CREATE OR REPLACE FUNCTION public.restore_suppressed_sale(p_suppressed_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sup     RECORD;
  v_company uuid;
  v_owner   uuid;
  v_new     RECORD;
BEGIN
  IF NOT public.i_am_admin() THEN
    RAISE EXCEPTION 'only admins can restore suppressed sales';
  END IF;

  SELECT ss.id, ss.embedded_id, ss.item_number, ss.item_price, ss.channel,
         ss.sale_seq, ss.device_created_at, ss.received_at, ss.product_id
  INTO v_sup
  FROM public.suppressed_sales ss
  WHERE ss.id = p_suppressed_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'suppressed sale not found';
  END IF;

  -- Company ownership via the originating device. owner_id may be NULL on
  -- legacy devices; sales.owner_id is nullable, so a NULL owner is acceptable.
  SELECT e.company, e.owner_id INTO v_company, v_owner
  FROM public.embeddeds e
  WHERE e.id = v_sup.embedded_id;

  IF v_company IS NULL OR v_company != public.my_company_id() THEN
    RAISE EXCEPTION 'suppressed sale does not belong to your company';
  END IF;

  -- Insert the real sale. The BEFORE-INSERT trigger resolves machine_id,
  -- applies tax, decrements stock by 1, and stamps product_id from the
  -- current tray. We override product_id with the snapshot just below.
  INSERT INTO public.sales
    (owner_id, embedded_id, item_number, item_price, channel, created_at, sale_seq, time_uncertain)
  VALUES
    (v_owner, v_sup.embedded_id, v_sup.item_number, v_sup.item_price, v_sup.channel,
     coalesce(v_sup.device_created_at, v_sup.received_at), v_sup.sale_seq, true)
  RETURNING id, created_at, machine_id, item_number, item_price, channel, product_id
  INTO v_new;

  -- Preserve the snapshot product (tray may have changed since suppression).
  IF v_sup.product_id IS NOT NULL THEN
    UPDATE public.sales SET product_id = v_sup.product_id WHERE id = v_new.id;
    v_new.product_id := v_sup.product_id;
  END IF;

  -- Remove from the auto-removed list.
  DELETE FROM public.suppressed_sales WHERE id = p_suppressed_id;

  -- Audit (user_id auto-fills via the activity_log column DEFAULT auth.uid()).
  INSERT INTO public.activity_log (company_id, entity_type, entity_id, action, metadata)
  VALUES (
    v_company, 'sale', v_new.id::text, 'sale_restored',
    jsonb_build_object(
      'source', 'suppressed_restore',
      'suppressed_id', p_suppressed_id,
      'item_number', v_sup.item_number,
      'item_price', v_sup.item_price,
      'machine_id', v_new.machine_id
    )
  );

  RETURN jsonb_build_object(
    'id', v_new.id,
    'created_at', v_new.created_at,
    'machine_id', v_new.machine_id,
    'item_number', v_new.item_number,
    'item_price', v_new.item_price,
    'channel', v_new.channel,
    'product_id', v_new.product_id
  );
EXCEPTION
  -- The suppressed seq was never inserted into sales, so a collision means a
  -- sale with this (embedded_id, sale_seq) was already recorded by another
  -- path. Surface a clear message instead of a raw 23505 to the caller.
  WHEN unique_violation THEN
    RAISE EXCEPTION 'a sale with this sequence number was already recorded for this device';
END;
$$;

GRANT EXECUTE ON FUNCTION public.restore_suppressed_sale(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_suppressed_sale(uuid) TO service_role;
