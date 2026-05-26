-- Populate provenance schema from existing "label" table in the current database
-- Usage: psql -h <host> -U <user> -d discogs -f sql/examples/discogs_labels_from_existing_db.sql

CREATE EXTENSION IF NOT EXISTS pgcrypto;

\i ../tables/provenance_graph.sql

BEGIN;

-- Ensure a Discogs data_source row exists (upsert by name)
INSERT INTO data_sources (id, name, kind, url, license)
VALUES (gen_random_uuid(), 'Discogs', 'dump', 'https://www.discogs.com/data/', null)
ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
RETURNING id;

-- Upsert source_records for every row in the existing label table
-- Map label.id -> source_key, store relevant columns into raw JSONB
WITH ds AS (
  SELECT id AS data_source_id FROM data_sources WHERE name = 'Discogs' LIMIT 1
), upsert_sr AS (
  INSERT INTO source_records (id, data_source_id, source_key, source_type, raw, url, retrieved_at)
  SELECT gen_random_uuid(), ds.data_source_id, l.id::text, 'label',
         jsonb_build_object(
           'id', l.id,
           'name', l.name,
           'contactinfo', l.contactinfo,
           'profile', l.profile,
           'parent_label', l.parent_label,
           'sublabels', to_jsonb(l.sublabels),
           'urls', to_jsonb(l.urls),
           'data_quality', l.data_quality
         )::jsonb,
         NULL,
         now()
  FROM label l, ds
  ON CONFLICT (data_source_id, source_key) DO UPDATE
    SET raw = EXCLUDED.raw,
        retrieved_at = EXCLUDED.retrieved_at
  RETURNING id, source_key
)
SELECT count(*) AS upserted_source_records FROM upsert_sr;

-- Create entities and provenance rows for records that are not yet mapped
WITH ds AS (
  SELECT id AS data_source_id FROM data_sources WHERE name = 'Discogs' LIMIT 1
), candidates AS (
  SELECT sr.id AS source_record_id,
         sr.source_key::int AS label_id,
         (sr.raw ->> 'name') AS source_name,
         sr.raw
  FROM source_records sr
  JOIN ds ON sr.data_source_id = ds.data_source_id
  LEFT JOIN entity_provenance ep ON ep.source_record_id = sr.id
  WHERE sr.source_type = 'label' AND ep.id IS NULL
), new_entities AS (
  SELECT gen_random_uuid() AS entity_id,
         c.source_record_id,
         c.source_name,
         jsonb_build_object('data_source_name', 'Discogs') AS props
  FROM candidates c
), ins_ent AS (
  INSERT INTO entities (id, entity_type, canonical_name, properties)
  SELECT entity_id, 'label', source_name, props FROM new_entities
  RETURNING id
), ins_prov AS (
  INSERT INTO entity_provenance (id, entity_id, source_record_id, role, evidence, confidence)
  SELECT gen_random_uuid(), ne.entity_id, ne.source_record_id, 'primary_label',
         jsonb_build_object('source_name', ne.source_name), 0.9
  FROM new_entities ne
  RETURNING id
)
SELECT count(*) AS provenance_inserted FROM ins_prov;

COMMIT;

-- Verification: list a few canonical entities and their Discogs source keys
\echo 'Sample canonical entities and provenance (first 20)'
SELECT e.id, e.canonical_name, sr.source_key
FROM entities e
JOIN entity_provenance ep ON ep.entity_id = e.id
JOIN source_records sr ON sr.id = ep.source_record_id
WHERE e.entity_type = 'label'
ORDER BY e.canonical_name
LIMIT 20;
