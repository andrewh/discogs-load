-- Idempotent upsert helpers for entities/relationships + provenance
-- Provides two convenience functions:
--  - upsert_entity_with_provenance(...)
--  - upsert_relationship_with_provenance(...)
-- These are intentionally small and opinionated: they match existing entities/relationships
-- by exact (entity_type, canonical_name) or (from, to, relation_type). They merge
-- properties with a simple JSONB || merge and upsert provenance rows.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Upsert an entity and attach provenance from a source_record.
-- Returns the canonical entity id.
CREATE OR REPLACE FUNCTION upsert_entity_with_provenance(
  p_source_record_id UUID,
  p_entity_type TEXT,
  p_canonical_name TEXT,
  p_properties JSONB DEFAULT '{}'::JSONB,
  p_role TEXT DEFAULT NULL,
  p_evidence JSONB DEFAULT '{}'::JSONB,
  p_confidence NUMERIC DEFAULT NULL
) RETURNS UUID AS $body$
DECLARE
  v_entity_id UUID;
BEGIN
  -- Try to find an existing entity by exact type + canonical_name
  SELECT id INTO v_entity_id
  FROM entities
  WHERE entity_type = p_entity_type AND canonical_name = p_canonical_name
  LIMIT 1;

  IF v_entity_id IS NULL THEN
    v_entity_id := gen_random_uuid();
    INSERT INTO entities (id, entity_type, canonical_name, properties)
    VALUES (v_entity_id, p_entity_type, p_canonical_name, COALESCE(p_properties, '{}'::JSONB));
  ELSE
    -- Merge properties: existing || new, new keys overwrite existing ones
    UPDATE entities
    SET properties = COALESCE(properties, '{}'::JSONB) || COALESCE(p_properties, '{}'::JSONB),
        updated_at = now()
    WHERE id = v_entity_id;
  END IF;

  -- Upsert provenance linking the entity to the source_record
  INSERT INTO entity_provenance (id, entity_id, source_record_id, role, evidence, confidence)
  VALUES (gen_random_uuid(), v_entity_id, p_source_record_id, p_role, COALESCE(p_evidence, '{}'::JSONB), p_confidence)
  ON CONFLICT (entity_id, source_record_id) DO UPDATE
    SET evidence = COALESCE(entity_provenance.evidence, '{}'::JSONB) || COALESCE(EXCLUDED.evidence, '{}'::JSONB),
        confidence = COALESCE(EXCLUDED.confidence, entity_provenance.confidence),
        asserted_at = now();

  RETURN v_entity_id;
END;
$body$ LANGUAGE plpgsql;


-- Upsert a relationship and attach provenance from a source_record.
-- Returns the relationship id.
CREATE OR REPLACE FUNCTION upsert_relationship_with_provenance(
  p_from_entity UUID,
  p_to_entity UUID,
  p_relation_type TEXT,
  p_properties JSONB DEFAULT '{}'::JSONB,
  p_source_record_id UUID,
  p_evidence JSONB DEFAULT '{}'::JSONB,
  p_confidence NUMERIC DEFAULT NULL
) RETURNS UUID AS $body$
DECLARE
  v_rel_id UUID;
BEGIN
  -- Try to find existing relationship (exact match)
  SELECT id INTO v_rel_id
  FROM relationships
  WHERE from_entity = p_from_entity AND to_entity = p_to_entity AND relation_type = p_relation_type
  LIMIT 1;

  IF v_rel_id IS NULL THEN
    v_rel_id := gen_random_uuid();
    INSERT INTO relationships (id, from_entity, to_entity, relation_type, properties)
    VALUES (v_rel_id, p_from_entity, p_to_entity, p_relation_type, COALESCE(p_properties, '{}'::JSONB));
  ELSE
    UPDATE relationships
    SET properties = COALESCE(properties, '{}'::JSONB) || COALESCE(p_properties, '{}'::JSONB),
        updated_at = now()
    WHERE id = v_rel_id;
  END IF;

  -- Upsert relationship provenance
  INSERT INTO relationship_provenance (id, relationship_id, source_record_id, evidence, confidence)
  VALUES (gen_random_uuid(), v_rel_id, p_source_record_id, COALESCE(p_evidence, '{}'::JSONB), p_confidence)
  ON CONFLICT (relationship_id, source_record_id) DO UPDATE
    SET evidence = COALESCE(relationship_provenance.evidence, '{}'::JSONB) || COALESCE(EXCLUDED.evidence, '{}'::JSONB),
        confidence = COALESCE(EXCLUDED.confidence, relationship_provenance.confidence),
        asserted_at = now();

  RETURN v_rel_id;
END;
$body$ LANGUAGE plpgsql;

-- Notes:
--  - Matching is conservative (exact matches). If you want fuzzy matching or
--    normalization, create a wrapper that normalizes strings and uses pg_trgm.
--  - The functions merge JSONB properties via || where later keys overwrite earlier ones.
--  - Provenance upserts append/merge evidence JSONB and prefer the new confidence when present.
