-- =========================================================
-- Seed system_tax_rates with EU + CH reference rates
--
-- Read-only reference table. Users never edit this directly.
-- When a company selects a country, the frontend copies
-- matching rows into company-specific tax_classes + tax_rates.
-- =========================================================

INSERT INTO public.system_tax_rates (country_code, tax_class_name, rate, name, valid_from) VALUES

-- Germany (DE)
('DE', 'standard',     0.1900, 'MwSt. 19%',  '2007-01-01'),
('DE', 'reduced',      0.0700, 'MwSt. 7%',   '2007-01-01'),

-- Austria (AT)
('AT', 'standard',     0.2000, 'USt. 20%',   '2016-01-01'),
('AT', 'reduced',      0.1000, 'USt. 10%',   '2016-01-01'),
('AT', 'intermediate', 0.1300, 'USt. 13%',   '2016-01-01'),

-- Switzerland (CH)
('CH', 'standard',     0.0810, 'MwSt. 8.1%', '2024-01-01'),
('CH', 'reduced',      0.0260, 'MwSt. 2.6%', '2024-01-01'),

-- France (FR)
('FR', 'standard',     0.2000, 'TVA 20%',    '2014-01-01'),
('FR', 'reduced',      0.0550, 'TVA 5.5%',   '2014-01-01'),
('FR', 'intermediate', 0.1000, 'TVA 10%',    '2014-01-01'),

-- Italy (IT)
('IT', 'standard',     0.2200, 'IVA 22%',    '2013-10-01'),
('IT', 'reduced',      0.0500, 'IVA 5%',     '2016-01-01'),
('IT', 'intermediate', 0.1000, 'IVA 10%',    '2013-10-01'),

-- Spain (ES)
('ES', 'standard',     0.2100, 'IVA 21%',    '2012-09-01'),
('ES', 'reduced',      0.1000, 'IVA 10%',    '2012-09-01'),

-- Netherlands (NL)
('NL', 'standard',     0.2100, 'BTW 21%',    '2012-10-01'),
('NL', 'reduced',      0.0900, 'BTW 9%',     '2019-01-01'),

-- Belgium (BE)
('BE', 'standard',     0.2100, 'TVA 21%',    '1996-01-01'),
('BE', 'reduced',      0.0600, 'TVA 6%',     '1996-01-01'),
('BE', 'intermediate', 0.1200, 'TVA 12%',    '1996-01-01'),

-- Poland (PL)
('PL', 'standard',     0.2300, 'VAT 23%',    '2011-01-01'),
('PL', 'reduced',      0.0800, 'VAT 8%',     '2011-01-01'),

-- Czech Republic (CZ)
('CZ', 'standard',     0.2100, 'DPH 21%',    '2015-01-01'),
('CZ', 'reduced',      0.1200, 'DPH 12%',    '2024-01-01'),

-- Portugal (PT)
('PT', 'standard',     0.2300, 'IVA 23%',    '2011-01-01'),
('PT', 'reduced',      0.0600, 'IVA 6%',     '2011-01-01'),
('PT', 'intermediate', 0.1300, 'IVA 13%',    '2011-01-01'),

-- Luxembourg (LU)
('LU', 'standard',     0.1700, 'TVA 17%',    '2024-01-01'),
('LU', 'reduced',      0.0800, 'TVA 8%',     '2024-01-01')

ON CONFLICT (country_code, tax_class_name, valid_from) DO NOTHING;
