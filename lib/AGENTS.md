# AGENTS.md (lib/)

- `adapter.ml`: `Provider.S`, `Sandbox.S`, the poller and webhook ingestion; the only
  module that talks to Grid through `Grid_api` and keeps state.
- `grid_api.ml`: Grid endpoints `lightspark-client` lacks, on its transport and redaction;
  views decode leniently (only the fields used, enums as strings). Money-moving writes go
  through `guarded` (the client's sandbox check).
- `*_map.ml`, `units.ml`, `payee.ml`, `refs.ml`: pure mappings, each tested in `test/`.
- `store.ml`: the record a service persists; record digests are pinned in tests.
- Keep the tables in each `.mli` and `docs/mapping.md` in step with the code.
