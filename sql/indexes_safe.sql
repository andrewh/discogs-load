-- Safe index creation: only create indexes/constraints when the referenced table exists.
-- Run with: psql -h <host> -U <user> -d <db> -f sql/indexes_safe.sql

DO $$
BEGIN
  -- release table and related indexes/PK
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'release') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pkey_release') THEN
      EXECUTE 'ALTER TABLE release ADD CONSTRAINT pkey_release PRIMARY KEY (id)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'idx_release') THEN
      EXECUTE 'CREATE INDEX idx_release ON release(id)';
    END IF;
  END IF;

  -- release_video
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'release_video') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'idx_release_video') THEN
      EXECUTE 'CREATE INDEX idx_release_video ON release_video(release_id)';
    END IF;
  END IF;

  -- release_label
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'release_label') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'idx_release_label') THEN
      EXECUTE 'CREATE INDEX idx_release_label ON release_label(release_id)';
    END IF;
  END IF;

  -- label table
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'label') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'idx_label') THEN
      EXECUTE 'CREATE INDEX idx_label ON label(id)';
    END IF;
  END IF;

  -- artist table
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'artist') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'idx_artist') THEN
      EXECUTE 'CREATE INDEX idx_artist ON artist(id)';
    END IF;
  END IF;

  -- master_artist
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'master_artist') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'idx_master_artist_master') THEN
      EXECUTE 'CREATE INDEX idx_master_artist_master ON master_artist(master_id)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'idx_master_artist_artist') THEN
      EXECUTE 'CREATE INDEX idx_master_artist_artist ON master_artist(artist_id)';
    END IF;
  END IF;

END$$;
