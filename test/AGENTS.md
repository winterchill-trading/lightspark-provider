# AGENTS.md (test/)

- `test_*.ml`: mappings and the adapter on `fixtures/` (redacted sandbox bodies: ids,
  e-mails, account numbers and addresses replaced; keep them that way).
- `fixture.ml`: a fake transport answering by method and path suffix; `test_adapter.ml`
  drives payouts, SCA, overdraft, swaps and webhooks through it.
- `fixtures/webhooks/`: bodies signed with a throwaway P-256 key (`public.pem`); re-sign
  with `openssl dgst -sha256 -sign` if a body changes.
- `test_store.ml` pins the stored record digests.
- `live/`: the conformance runner and the USD walk; they print a skip line unless
  `LIGHTSPARK_LIVE_TESTS=1` and the token are set, and create sandbox data when they run.
- Promote expect output with `dune promote` (from the workspace root) after reading the
  diff. Print fixed times, never the clock.
