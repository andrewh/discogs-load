Quick facts
- This is a small Rust workspace with two crates: `discogs-load` (the app) and `xtask` (release/install helper). See top-level Cargo.toml workspace members.
- Primary entrypoint: `discogs-load/src/main.rs` (binary `discogs-load`).

How to run a quick local verification
- Start a local Postgres used by CI and README: `docker-compose up -d postgres`.
- Use the small sample data under `discogs-load/test_data` to avoid huge files. Example:
  `cargo run --bin discogs-load discogs-load/test_data/releases.xml.gz`
- If Postgres is on another host or port, pass DB flags. Defaults are: `--db-host localhost --db-user dev --db-password dev_pass --db-name discogs`.
- If you want indexes created after load, pass `--create-indexes` (top-level flag).

Exact commands you will need frequently
- Build locally (debug): `cargo build --bin discogs-load`.
- Run (uses defaults shown above): `cargo run --bin discogs-load <path/to/file(s).gz>`.
- Build release binary: `cargo build --bin discogs-load --release`.
- Create platform-specific compressed dist (uses `xtask`): `cargo xtask dist` (alias defined in `.cargo/config`).
- Install the binary to `~/.cargo/bin`: `cargo xtask install`.

xtask / release notes
- `.cargo/config` defines `cargo xtask` alias which runs the `xtask` crate.
- `cargo xtask dist` expects `DIST_TARGET` env var when cross-building. The CI sets `DIST_TARGET` per-matrix; set it locally if you need a non-default target.
- `xtask dist` builds the `discogs-load` binary for the target and writes gzipped artifacts into `./dist` (this is what the release workflow uploads).

CI and reproducible verification
- The GitHub Actions CI (`.github/workflows/ci.yml`) simply runs a Postgres service then runs `cargo run --bin discogs-load` against the three small test files in `discogs-load/test_data` (releases, labels, artists, masters). Reproduce locally with the same files and `docker-compose up -d postgres`.
- The release workflow (`.github/workflows/release.yml`) triggers only on tag pushes matching `v*.*.*` and uses `cargo xtask dist` to produce multi-platform artifacts.

Schema and indexes
- Table creation SQLs are under `sql/tables/*.sql` and indexes are in `sql/indexes.sql`.
- The binary runs `db::init(...)` automatically when it detects the file type (labels/releases/artists/masters) before inserting rows. You do not need to run the SQL manually for normal runs.
- Indexes are created only when you run the binary with `--create-indexes` (or set the `create_indexes` flag via CLI).

Database connection and important flags
- The program builds a Postgres connection string from flags in `db::DbOpt` (flattened into top-level CLI): `host`, `user`, `password`, `dbname`. Defaults: host=localhost, user=dev, password=dev_pass, dbname=discogs.
- Batch insert size default: `--batch-size 10000`.

Data files and format
- Input must be Discogs XML monthly dumps, still gz-compressed. The code expects the root tag to be one of `labels`, `releases`, `artists`, or `masters` and will choose schema accordingly.
- Small gzipped examples are present at `discogs-load/test_data/*.xml.gz` for fast testing.

Repository layout pointers (high-signal)
- Workspace members: `discogs-load/` (app), `xtask/` (release helpers).
- SQL schema: `sql/tables/*.sql`, `sql/indexes.sql`.
- Docker compose: `docker-compose.yml` defines `postgres` service used in README and CI.
- Release dist: `xtask` writes artifacts to `./dist`.

Common gotchas an agent would miss
- Always start Postgres before running the binary; CI relies on `docker-compose up -d postgres` and the service healthcheck—local Postgres may need time to become ready.
- Use the small `test_data` files when iterating locally; the real dumps are huge and expensive to parse.
- `cargo xtask` is available because of `.cargo/config` alias; calling the `xtask` crate directly with `cargo run --package xtask --bin xtask -- <cmd>` is equivalent but longer.
- When cross-building via `xtask dist`, set `DIST_TARGET` to the target triple you want; otherwise xtask picks a default based on the host compile cfg which may be wrong for cross builds.

If you need more context
- README.md contains example usage and sample commands — follow it for basic flows.
- Look at `.github/workflows/*` to see exactly what CI and release steps expect.

If something is missing here or you find a stale instruction, update this file — it exists to stop future agents from guessing.

Recent work and repo additions
- Added a provenance-aware graph schema and example ingestion artifacts for Discogs data. Key new files:
  - sql/tables/provenance_graph.sql (provenance schema: data_sources, source_records, entities, relationships, provenance views)
  - sql/examples/discogs_labels_example.sql (small example that inserts two label source_records + entities + provenance)
  - sql/examples/discogs_labels_from_existing_db.sql (imports source_records and creates entities/provenance from existing label table)
  - sql/functions/upsert_helpers.sql (PL/pgSQL helpers: upsert_entity_with_provenance, upsert_relationship_with_provenance)
  - sql/indexes_safe.sql (idempotent/conditional index creation script)
  - scripts/run_discogs_import_and_tune.sh (helper to build, ALTER SYSTEM tune, run import, create indexes, revert settings)

What I ran here (practical, reproducible steps)
- Built release binary: cargo build --release --bin discogs-load
- Import large files with release binary (example used in this session):
  ./target/release/discogs-load ./discogs_20260501_releases.xml.gz --db-host localhost --db-user dev --db-password dev_pass --db-name discogs --batch-size 50000
  ./target/release/discogs-load ./discogs_20260501_artists.xml.gz --db-host localhost --db-user dev --db-password dev_pass --db-name discogs --batch-size 50000
- Index creation: prefer sql/indexes_safe.sql which only creates indexes for existing tables:
  psql -h localhost -U dev -d discogs -f sql/indexes_safe.sql
- ANALYZE after large loads to refresh planner statistics:
  psql -h localhost -U dev -d discogs -c "ANALYZE VERBOSE release;"

Notable runtime/operational details and fixes
- The loader's CLI does not accept a --db-port flag; pass --db-host, --db-user, --db-password, --db-name only.
- The releases parser initially panicked due to unchecked unwrap() on XML attributes. I hardened the parser to defensively parse attributes by name and avoid unwraps. If you hit an early crash, ensure you have the latest commit that handles malformed/missing attributes.
- For large dumps run the release binary in release mode and create indexes after loading. Creating indexes during insert is much slower and may fail if dependent tables are missing.
- I added a small wrapper script (scripts/run_discogs_import_and_tune.sh) that will: build a release binary, optionally apply ALTER SYSTEM tuning (synchronous_commit = off; maintenance_work_mem = 1GB), run the import (nohup background), create indexes after import, then revert ALTER SYSTEM changes.
  - ALTER SYSTEM requires superuser privileges. If you do not have superuser access, the script will continue without applying sys-tuning.

Discovery notes and gotchas encountered while importing
- Import of releases (large file) succeeded; index creation failed initially because sql/indexes.sql referenced tables (artist) that were not present — use sql/indexes_safe.sql instead.
- The process can be long-running: release import produced ~19M release rows (~6GB heap). Use nohup/tmux and monitor logs (import_run*.log).
- If parser panics, run with RUST_BACKTRACE=1 to see stack traces. I fixed a panic in releases parser earlier.
- The importer writes to the DB tables defined by sql/tables/*.sql; check these files to know which tables will be created for a given dump type (release/label/artist/master).
- When importing artists/releases/masters/labels separately, create indexes only after importing the tables that indexes reference, or use indexes_safe.sql.

State observed on the working DB (as imported in this session)
- release: ~19,087,916 rows (approx, ANALYZE estimate); heap ~6.0 GB; total ~7.0 GB
- release_label: ~7,652,252 rows
- release_video: ~11,158,433 rows
- label: 2,372,322 rows
- master: 2,551,002 rows
- master_artist: 3,132,578 rows
- artist: 10,039,040 rows

Indexes created during session (safe script)
- idx_release, pkey_release on release
- idx_release_label on release_label(release_id)
- idx_release_video on release_video(release_id)
- idx_artist on artist(id)
- idx_label on label(id)
- idx_master_artist_master and idx_master_artist_artist on master_artist

Performance tips
- Use cargo build --release for importing large dumps; debug builds are much slower.
- Increase batch-size for a fast server (I used 50000 here). If you see OOM or memory issues, reduce it.
- Disable synchronous_commit and increase maintenance_work_mem during bulk load for speed (requires superuser). Revert after load.
- Create indexes after the bulk load, not during. Use conditional index script if you import files in stages.

Useful commands collected from session
- Start Postgres locally (docker): docker-compose up -d postgres
- Create role & DB:
  psql -h localhost -U postgres -c "CREATE ROLE dev WITH LOGIN PASSWORD 'dev_pass';" || true
  psql -h localhost -U postgres -c "CREATE DATABASE discogs OWNER dev;" || true
- Import releases (release build, background):
  nohup ./target/release/discogs-load /path/to/releases.xml.gz --db-host localhost --db-user dev --db-password 'dev_pass' --db-name discogs --batch-size 50000 > import_release.log 2>&1 &
- Create safe indexes: psql -h localhost -U dev -d discogs -f sql/indexes_safe.sql
- Analyze tables: psql -h localhost -U dev -d discogs -c "ANALYZE VERBOSE release;"
- Tail logs: tail -f import_release.log

If anything here looks wrong or you want a different policy (for example, different index names, different normalization/merge policy for entities), update this file or tell me and I will make the minimal changes required.
