-- =========================================================
-- Machine Address Fields
--
-- Adds structured address columns + formatted_address cache
-- to vendingMachine. Coordinates (location_lat/location_lon)
-- and country_code already exist from prior migrations.
--
-- All columns nullable — legacy machines and the existing
-- createMachine(name, company) flow continue to work.
-- Backward-compatible: no firmware or edge-function changes
-- are required.
-- =========================================================

ALTER TABLE public."vendingMachine"
  ADD COLUMN address_street       text,
  ADD COLUMN address_house_number text,
  ADD COLUMN address_postal_code  text,
  ADD COLUMN address_city         text,
  ADD COLUMN formatted_address    text;

COMMENT ON COLUMN public."vendingMachine".address_street       IS 'Street name from Nominatim address.road';
COMMENT ON COLUMN public."vendingMachine".address_house_number IS 'House number from Nominatim address.house_number';
COMMENT ON COLUMN public."vendingMachine".address_postal_code  IS 'Postal code from Nominatim address.postcode';
COMMENT ON COLUMN public."vendingMachine".address_city         IS 'City/town/village from Nominatim address (first of city/town/village/municipality)';
COMMENT ON COLUMN public."vendingMachine".formatted_address    IS 'Cached display_name from Nominatim, full human-readable address';
