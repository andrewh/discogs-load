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
