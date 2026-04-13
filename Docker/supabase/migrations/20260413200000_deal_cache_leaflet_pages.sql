-- =========================================================
-- Add leaflet_pages column to deal_cache
--
-- Stores the prospekt page images (jsonb array) fetched from
-- the marktguru leafletFlights API, so the frontend can show
-- the actual leaflet page the offer appears on.
--
-- Format: [{"pageNumber": 0, "imageUrl": "https://..."}]
-- =========================================================

ALTER TABLE public.deal_cache
  ADD COLUMN IF NOT EXISTS leaflet_pages jsonb;
