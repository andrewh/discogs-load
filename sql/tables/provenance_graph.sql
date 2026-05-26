-- Provenance-aware graph schema (domain-oriented names)
-- Principles:
--  - Canonical rows are our interpretation: `entities` and `relationships`.
--  - External data is stored as `data_sources` -> `source_records`.
--  - Provenance mappings link canonical rows to source records and carry evidence/confidence.
--  - Do NOT store upstream IDs as columns on canonical rows; keep them in source_records.

DROP TABLE IF EXISTS relationship_provenance CASCADE;
DROP TABLE IF EXISTS relationships CASCADE;
DROP TABLE IF EXISTS entity_provenance CASCADE;
DROP TABLE IF EXISTS entities CASCADE;
DROP TABLE IF EXISTS source_records CASCADE;
DROP TABLE IF EXISTS data_sources CASCADE;

CREATE TABLE data_sources (
  id UUID PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL, -- dump | api | scrape | manual | user
  url TEXT,
  license TEXT,
  created_at TIMESTAMP DEFAULT now()
);

-- Upstream record: one row per record coming from a data source (eg: a Discogs artist JSON)
CREATE TABLE source_records (
  id UUID PRIMARY KEY,
  data_source_id UUID NOT NULL REFERENCES data_sources(id) ON DELETE CASCADE,
  source_key TEXT,       -- opaque identifier within the source (eg: "artist/12345")
  source_type TEXT,      -- optional type as declared by the source (artist, release, label...)
  raw JSONB,             -- raw or lightly-normalised payload from the source
  url TEXT,              -- link back to upstream record when available
  retrieved_at TIMESTAMP,
  created_at TIMESTAMP DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS source_records_unique ON source_records(data_source_id, source_key);
CREATE INDEX IF NOT EXISTS source_records_by_source ON source_records(data_source_id);
CREATE INDEX IF NOT EXISTS source_records_source_type_idx ON source_records(source_type);
CREATE INDEX IF NOT EXISTS source_records_raw_gin ON source_records USING GIN (raw jsonb_path_ops);

-- Canonical entities (our domain objects). Keep schema generic and source-agnostic.
CREATE TABLE entities (
  id UUID PRIMARY KEY,
  entity_type TEXT NOT NULL, -- artist | label | release | work | recording | place | person | organisation | ...
  canonical_name TEXT,       -- preferred label
  properties JSONB DEFAULT '{}'::JSONB, -- our canonical attributes
  created_at TIMESTAMP DEFAULT now(),
  updated_at TIMESTAMP
);
CREATE INDEX IF NOT EXISTS entities_type_idx ON entities(entity_type);
CREATE INDEX IF NOT EXISTS entities_properties_gin ON entities USING GIN (properties jsonb_path_ops);

-- Provenance: link a canonical entity to one or more upstream source_records
CREATE TABLE entity_provenance (
  id UUID PRIMARY KEY,
  entity_id UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  source_record_id UUID NOT NULL REFERENCES source_records(id) ON DELETE CASCADE,
  role TEXT,               -- optional role of the source record (primary_name, alias, member_list, etc.)
  evidence JSONB DEFAULT '{}'::JSONB, -- extracted facts used for the match
  confidence NUMERIC,      -- 0..1 recommended
  asserted_at TIMESTAMP DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS entity_provenance_unique ON entity_provenance(entity_id, source_record_id);
CREATE INDEX IF NOT EXISTS entity_provenance_entity_idx ON entity_provenance(entity_id);
CREATE INDEX IF NOT EXISTS entity_provenance_source_idx ON entity_provenance(source_record_id);
CREATE INDEX IF NOT EXISTS entity_provenance_confidence_idx ON entity_provenance((confidence));

-- Canonical relationships between entities
CREATE TABLE relationships (
  id UUID PRIMARY KEY,
  from_entity UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  to_entity UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  relation_type TEXT NOT NULL, -- performed_by | member_of | released_on | same_as | influenced_by | etc.
  properties JSONB DEFAULT '{}'::JSONB, -- qualifiers, roles, dates, provenance-neutral attributes
  created_at TIMESTAMP DEFAULT now(),
  updated_at TIMESTAMP
);
CREATE INDEX IF NOT EXISTS relationships_from_idx ON relationships(from_entity);
CREATE INDEX IF NOT EXISTS relationships_to_idx ON relationships(to_entity);
CREATE INDEX IF NOT EXISTS relationships_type_idx ON relationships(relation_type);
CREATE INDEX IF NOT EXISTS relationships_properties_gin ON relationships USING GIN (properties jsonb_path_ops);

-- Provenance: link a canonical relationship to upstream evidence records
CREATE TABLE relationship_provenance (
  id UUID PRIMARY KEY,
  relationship_id UUID NOT NULL REFERENCES relationships(id) ON DELETE CASCADE,
  source_record_id UUID NOT NULL REFERENCES source_records(id) ON DELETE CASCADE,
  evidence JSONB DEFAULT '{}'::JSONB,
  confidence NUMERIC,
  asserted_at TIMESTAMP DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS relationship_provenance_unique ON relationship_provenance(relationship_id, source_record_id);
CREATE INDEX IF NOT EXISTS relationship_provenance_rel_idx ON relationship_provenance(relationship_id);
CREATE INDEX IF NOT EXISTS relationship_provenance_source_idx ON relationship_provenance(source_record_id);

-- Convenience views for quick provenance lookup
CREATE OR REPLACE VIEW entity_provenance_view AS
SELECT e.id AS entity_id,
  e.entity_type,
  e.canonical_name,
  ds.id AS data_source_id,
  ds.name AS data_source_name,
  sr.id AS source_record_id,
  sr.source_key,
  sr.source_type,
  ep.role,
  ep.evidence,
  ep.confidence,
  ep.asserted_at
FROM entities e
JOIN entity_provenance ep ON ep.entity_id = e.id
JOIN source_records sr ON sr.id = ep.source_record_id
JOIN data_sources ds ON ds.id = sr.data_source_id;

CREATE OR REPLACE VIEW relationship_provenance_view AS
SELECT r.id AS relationship_id,
  r.relation_type,
  r.from_entity,
  r.to_entity,
  ds.id AS data_source_id,
  ds.name AS data_source_name,
  sr.id AS source_record_id,
  sr.source_key,
  rp.evidence,
  rp.confidence,
  rp.asserted_at
FROM relationships r
JOIN relationship_provenance rp ON rp.relationship_id = r.id
JOIN source_records sr ON sr.id = rp.source_record_id
JOIN data_sources ds ON ds.id = sr.data_source_id;

-- Notes:
--  - UUIDs are used everywhere to allow durable, portable identifiers across systems.
--  - JSONB columns allow the schema to evolve without frequent DDL changes. Indexes use jsonb_path_ops for compact GIN indexes.
--  - Keep source-side identifiers in source_records.source_key; do not copy them to entities/relationships.
--  - Ingest pipelines should create source_records first, then entities/relationships, then provenance rows that link them.
