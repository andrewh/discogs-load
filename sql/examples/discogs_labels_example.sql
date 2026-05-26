-- Example: populate the provenance-aware graph schema with a small Discogs labels dataset
-- Run with: psql -h <host> -U <user> -d <db> -f sql/examples/discogs_labels_example.sql

-- pgcrypto provides gen_random_uuid(); adjust if your environment prefers uuid-ossp
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Load schema (uses relative path; run from repo root or adjust path)
\i ../tables/provenance_graph.sql

BEGIN;

-- Insert a data source for Discogs
WITH discogs AS (
  INSERT INTO data_sources (id, name, kind, url, license)
  VALUES (gen_random_uuid(), 'Discogs', 'dump', 'https://www.discogs.com/data/', 'unknown')
  RETURNING id
),

-- Insert two source_records (labels) from Discogs
sr1 AS (
  INSERT INTO source_records (id, data_source_id, source_key, source_type, raw, url, retrieved_at)
  SELECT gen_random_uuid(), id, '1', 'label',
         jsonb_build_object(
           'id', 1,
           'name', 'Planet E',
           'contactinfo', 'Planet E Communications',
           'urls', jsonb_build_array('http://planet-e.net')
         )::jsonb,
         'https://www.discogs.com/label/1', now()
  FROM discogs
  RETURNING id
),
sr2 AS (
  INSERT INTO source_records (id, data_source_id, source_key, source_type, raw, url, retrieved_at)
  SELECT gen_random_uuid(), id, '4', 'label',
         jsonb_build_object(
           'id', 4,
           'name', 'Siesta Music',
           'contactinfo', 'Siesta Records, San Diego',
           'urls', jsonb_build_array('http://www.siestarecords.com')
         )::jsonb,
         'https://www.discogs.com/label/4', now()
  FROM discogs
  RETURNING id
),

-- Insert canonical entities representing the labels (our interpretation)
e1 AS (
  INSERT INTO entities (id, entity_type, canonical_name, properties)
  VALUES (gen_random_uuid(), 'label', 'Planet E', jsonb_build_object('country','US'))
  RETURNING id
),
e2 AS (
  INSERT INTO entities (id, entity_type, canonical_name, properties)
  VALUES (gen_random_uuid(), 'label', 'Siesta Music', jsonb_build_object('country','US'))
  RETURNING id
),

-- Link the canonical entities to the source records (provenance mapping)
ep1 AS (
  INSERT INTO entity_provenance (id, entity_id, source_record_id, role, evidence, confidence)
  SELECT gen_random_uuid(), e1.id, sr1.id, 'primary_label',
         jsonb_build_object('name_match', true, 'source_name', 'Planet E'), 0.95
  FROM e1, sr1
  RETURNING id
),
ep2 AS (
  INSERT INTO entity_provenance (id, entity_id, source_record_id, role, evidence, confidence)
  SELECT gen_random_uuid(), e2.id, sr2.id, 'primary_label',
         jsonb_build_object('name_match', true, 'source_name', 'Siesta Music'), 0.9
  FROM e2, sr2
  RETURNING id
)
SELECT 1;

COMMIT;

-- Quick verification queries
\echo 'Entities:'
SELECT id, entity_type, canonical_name, properties FROM entities ORDER BY canonical_name;
\echo 'Source records:'
SELECT sr.id, ds.name AS source_name, sr.source_key, sr.source_type, sr.raw->>'name' AS source_name_field
FROM source_records sr JOIN data_sources ds ON ds.id = sr.data_source_id ORDER BY sr.source_key;
\echo 'Provenance mapping:'
SELECT ep.entity_id, e.canonical_name, ep.source_record_id, sr.source_key, ep.evidence, ep.confidence
FROM entity_provenance ep
JOIN entities e ON e.id = ep.entity_id
JOIN source_records sr ON sr.id = ep.source_record_id;
