# AGENTS.md

## Purpose

This library implements `banking-provider`'s `Provider.S` and `Sandbox.S` over the
Lightspark Grid API (`lightspark-client`): customers and KYC, USD and stablecoin accounts,
cross-border payouts with Grid's FX quotes, wallet and Lightning payouts, conversions as
swaps, statements and signed webhooks normalized into `banking-provider` events. Cards and
standing orders answer an error.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | Library `lightspark_provider`: `Adapter`, `Grid_api`, `Store`, `Refs`, `Units`, `Payee`, `Kyc_map`, `Account_map`, `Tx_map`, `Grid_time` (see `lib/AGENTS.md`) |
| `bin/` | `lightspark-provider` CLI: `customer`, `fee` (read-only) |
| `test/` | Mapping and adapter tests on redacted fixtures, live runners in `test/live/` (see `test/AGENTS.md`) |
| `examples/` | `quick_start.ml`, built in CI |
| `docs/` | `mapping.md` (operations, events, currencies, rails, KYC, SCA, gaps), `api-notes.md` (sandbox findings) |
| `.github/` | CI workflow |
| `dune-project`, `lightspark-provider.opam` | Package metadata; the `.opam` file is generated |

## Build, test, docs

Run from this directory; the workspace root `..` holds the sibling checkouts.

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @lightspark-provider/all
opam exec --switch 5.2.0+ox -- dune build --root .. @lightspark-provider/runtest
opam exec --switch 5.2.0+ox -- dune build --root .. @lightspark-provider/doc
DUNE_BUILD_DIR=_build-lightspark-provider opam exec --switch 5.2.0+ox -- dune build --root .. @lightspark-provider/all
```

The last line gives parallel work its own build directory (resolved from the workspace
root). Live runs need a Grid sandbox token in the gitignored `.env`:

```sh
set -a; . ./.env; set +a
LIGHTSPARK_LIVE_TESTS=1 opam exec --switch 5.2.0+ox -- dune build --root .. @lightspark-provider/runtest
```

`LIGHTSPARK_LIVE_WALK=1` adds the USD walk. Standalone: pin the siblings listed in
`.github/workflows/ci.yml`, then `opam install . --deps-only --with-test && dune build && dune test`.

## Conventions

- Formatting: `dune build --root .. @lightspark-provider/fmt --auto-promote`, after the
  tests pass. Never `dune fmt` at the workspace root.
- Every module has an `.mli` with odoc on every public value; CI fails on odoc warnings.
- `Store.Transfer_record` and `Store.Swap_record` are stable with pinned digests
  (`test/test_store.ml`); changing them is a version decision.
- Event ids are derived from Grid data (`tx:<id>:<STATUS>`, `kyc:...`) so poll and webhook
  agree; keep that when adding an event.
- Every Grid create carries an `Idempotency-Key` built from our ids.
- Comments for humans at non-obvious choices; a `CHANGES.md` "Unreleased" entry for
  user-visible changes; update `docs/mapping.md` when a mapping changes.

## Dependencies and dependents

- Depends on: `money`, `ledger`, `kyc-core`, `payments-core`, `card-core`,
  `banking-provider`, `lightspark-client` (and `fixed-decimal` through them).
- Used by: services that route USD accounts to Grid through `banking-provider`.
- CI pin order: `fixed-decimal`, `money`, `ledger`, `kyc-core`, `payments-core`,
  `card-core`, `banking-provider`, `lightspark-client`.

## CI

`.github/workflows/ci.yml` runs the `ox-setup` action with those pins (cached switch),
`dune build`, `dune build @examples/all`, `dune test` (live runners print a skip line) and
`dune build @doc` with warnings as failures; the `obj-magic` job rejects `Obj.magic`.
Check with `gh run list --limit 1`, then at most one `gh run watch <id> --exit-status`.

## Pitfalls

- The sandbox platform holds USD, USDC, USDT and USDB only; the conformance suite opens an
  EUR account first, so only 3 of 11 scenarios can pass; `test/live/walk.ml` covers USD.
- USD to EUR quotes need `senderCustomerInfo.PURPOSE_OF_PAYMENT`.
- `totalBalance` lags settled payouts on the sandbox; balances use `balance` only.
- Balance-change statements answer 501 for customer accounts; statements fall back to
  transactions.
- A conversion between a customer's own accounts shows as an `INCOMING` transaction; look
  up swaps by quote id before treating it as a deposit.
- Inside `Deferred.Or_error.Let_syntax`, `return` wraps in `Ok`; use `Deferred.return` for
  an `Or_error` value.
- `Pipe.close_read` drops queued events; read with `Pipe.read_now'` first in tests.

## Where to read more

- `README.md`, `docs/mapping.md`, `docs/api-notes.md`, `CHANGES.md`.
- `../lightspark-client/docs/api-notes.md`; `../specs/repos/lightspark-provider.md` when present.
- Skills in `../oxcaml-claude-skills/skills/`: `banking-standards`, `janestreet-ocaml-style`.
- `../oxcaml-claude-skills/AGENTS.md`: the workspace-wide guide; `../oxcaml-claude-skills/GOTCHAS.md`.

## Never do

- Install or upgrade opam packages on the shared `5.2.0+ox` switch without a dry run;
  abort if the plan touches `ocaml-variants`, `core`, `base`, `async` or `ppx_jane`.
- Publish, tag or release.
- Commit `.env` or print the token; credentials come only from the environment.
- Call endpoints that change platform settings (webhook URL, tokens, config).
- Poll CI in a loop.
