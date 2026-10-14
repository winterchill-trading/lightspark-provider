# lightspark-provider

[banking-provider](https://github.com/winterchill-trading/banking-provider)'s
`Provider.S` and `Sandbox.S` implemented over the Lightspark Grid API
([lightspark-client](https://github.com/winterchill-trading/lightspark-client)):
customers and their KYC state, USD and stablecoin accounts, cross-border payouts to bank
accounts with Grid's FX quotes, payouts to wallets and Lightning, conversions between a
customer's own accounts as swaps, statements, and webhooks normalized into
banking-provider events. Sandbox by default. Cards are not offered.

## Why separate

`banking-provider` describes what an application needs from any banking-as-a-service
provider and stays free of provider names; `lightspark-client` is a plain SDK for one
API. This adapter is the only place that knows both, so an application written against
`Provider.S` runs unchanged on the fake provider in tests and on Grid in production.

## Quick start

```sh
cp .env.example .env                  # a Grid sandbox token from the dashboard
set -a; . ./.env; set +a
dune build
LIGHTSPARK_LIVE_TESTS=1 dune test     # also runs the conformance suite on the sandbox
dune exec examples/quick_start.exe    # onboard, open USD, credit 25.00 USD
```

```ocaml
module A = Lightspark_provider.Adapter

let%bind.Deferred.Or_error adapter = return (A.of_env ()) in
let%bind.Deferred.Or_error customer = A.create_customer adapter ~customer_id ~person in
(* Grid opens the USD account itself a moment after the customer; this waits for it. *)
let%bind.Deferred.Or_error usd = A.open_account adapter customer.id Money.Currency.usd in
(* A SEPA draft in EUR from the USD account: Grid quotes the FX, the fee is in USD. *)
A.initiate_transfer adapter ~from:usd.id draft
```

A service passes its own `Store.t` (links from our transfer and swap ids to Grid quotes,
persisted in its database) and hands each webhook delivery to `ingest_webhook`. Without
a public webhook URL the adapter polls customers and their transactions while `events`
has a subscriber.

## Environment

| Variable                             | Required | Purpose |
| ------------------------------------ | -------- | ------- |
| `LIGHTSPARK_CLIENT_ID`               | yes      | Grid token id (HTTP Basic user) |
| `LIGHTSPARK_CLIENT_SECRET`           | yes      | Grid token secret |
| `LIGHTSPARK_GRID_URL`                | no       | defaults to `https://api.lightspark.com/grid/2025-10-13` |
| `LIGHTSPARK_GRID_WEBHOOK_PUBLIC_KEY` | no       | the platform's PEM key for `X-Grid-Signature` (newlines may be `\n`); without it every webhook is refused |
| `LIGHTSPARK_LIVE_TESTS`              | no       | `1` lets `dune test` run the conformance suite on the sandbox |
| `LIGHTSPARK_LIVE_WALK`               | no       | `1` (with the above) also runs the USD walk |
| `LIGHTSPARK_CONFORMANCE_ONLY`        | no       | runs only the scenarios whose name contains this text |
| `LIGHTSPARK_RECORD_DIR`              | no       | lightspark-client writes every response here (for fixtures) |

Credentials are read only from the environment and never logged; error bodies pass
through lightspark-client's redaction. Money-moving writes are refused unless
`GET /config` says the platform is a sandbox or the config was built with
`~live:true`; the `Sandbox.S` calls refuse live configs outright.

## Modules

| Module        | What it does |
| ------------- | ------------ |
| `Adapter`     | `Provider.S`, `Sandbox.S`, webhook ingestion, the poller, `us_bank_details` |
| `Grid_api`    | the Grid endpoints lightspark-client does not cover (external accounts, quotes with SCA, balance changes, contact verification, KYC links, test webhooks) and lenient object views |
| `Store`       | links Grid cannot hold (our transfer and swap ids to quotes and transactions, open SCA challenges), with an in-memory implementation |
| `Refs`        | account references carrying the owning customer |
| `Units`       | Grid currencies and smallest units in `money` terms, exact |
| `Payee`       | beneficiaries as Grid external accounts and payment rails |
| `Kyc_map`     | `kycStatus` and contact verification to kyc-core steps, status and events |
| `Account_map` | internal accounts, funding instructions and balances |
| `Tx_map`      | transaction statuses and failure reasons to transfer updates and deposits |
| `Grid_time`   | timestamps |

[docs/mapping.md](docs/mapping.md) lists every operation with its Grid endpoints, every
webhook and transaction status with its event, the currency, rail, KYC and SCA mappings,
and the gaps. [docs/api-notes.md](docs/api-notes.md) records what the sandbox showed;
[AGENTS.md](AGENTS.md) is the guide for coding agents.

## Coverage

| Area | Verified live (sandbox) | Fixtures only |
| ---- | ----------------------- | ------------- |
| Customers: create, find by our id, KYC status | yes | KYC webhooks |
| Contact verification, hosted KYC link | | not exercised (US customers need neither) |
| Accounts: open (wait), list, balance, US bank details | yes | |
| Sandbox deposit and its `Incoming_transfer` event | yes | inbound webhooks |
| Fee quote from exchange rates | yes | |
| Cross-border payout USD to EUR by SEPA, events Submitted, Pending, Settled; resend pays once | yes | |
| Payout refused by the partner (refunded) | yes | other failure reasons |
| USDC payout to an Ethereum wallet | yes | |
| Conversion USD to USDC as a swap, `Swap_executed` | yes | |
| Statement (transaction fallback) | yes | balance-change path |
| SCA challenge, wrong code, authorization | | yes (US customers get none) |
| Overdraft refusal | | yes |
| Webhook signature, normalization, redelivery | | yes (signed with a throwaway key) |
| `ping` | refused: no webhook URL on the platform | yes |

## CLI

```
lightspark-provider customer -id Customer:...
lightspark-provider fee -account Customer:.../InternalAccount:... -amount '30.00 EUR' [-instant]
```

Both are read-only (a fee quote reads exchange rates).

## Conformance

`test/live/live.exe` runs `banking-provider`'s `Conformance` functor against the sandbox
when `LIGHTSPARK_LIVE_TESTS=1` and the credentials are set; otherwise it prints one line
and passes, which is what CI sees. Each run creates sandbox customers prefixed with a
timestamp, using the suite's own timeouts (10 s per awaited state).

Run on 2026-10-14 against the Grid sandbox: 3 passed, 8 failed.

| Scenario | Result |
| -------- | ------ |
| create_customer is idempotent on our customer id | pass |
| a KYC approval is published as an event and reported by kyc_status | pass |
| a webhook with a bad signature is refused | pass |
| an approved customer gets an EUR account with an IBAN | fail: no EUR accounts on this platform |
| a deposit is published once and credits the balance | fail: no EUR account |
| a payment confirmed by SCA settles and debits amount plus fee | fail: no EUR account |
| initiating the same transfer twice pays once | fail: no EUR account |
| a payment above the balance does not leave the account | fail: no EUR account |
| a wrong SCA code is refused without naming a factor | fail: no EUR account |
| a test delivery arrives as a Ping event | fail: `WEBHOOK_ENDPOINT_NOT_SET` |
| a virtual card is approved, and declined with 57 once frozen | fail: no EUR account (cards are not offered anyway) |

The suite is written around an EUR account with an IBAN; this platform holds USD, USDC,
USDT and USDB only (`GET /config`), so every scenario that opens one stops there. The
same steps in dollars run in `test/live/walk.exe` (`LIGHTSPARK_LIVE_WALK=1`), which
passed on the same day: deposit, fee quote, a SEPA payout settled and paid once on
resend, a refused payout refunded, a conversion, a USDC wallet payout and a statement
whose lines add up. It prints statuses and amounts, never ids or personal data.

## Tests

`dune test` runs the expect tests on redacted sandbox responses and documented bodies
(`test/fixtures`: ids, e-mails, account numbers and addresses replaced): unit
conversions with a round-trip property, KYC mapping and event ids, accounts and US bank
details, every transaction status and failure reason, payees, and the adapter over a
fake transport (payouts with and without SCA, overdraft, swap, signed webhooks and
redelivery). Then the two live executables, which skip without credentials.

## Storage

This is a library: it persists nothing. The `Store.t` record of functions is what a
service implements over its own database; `Store.memory` serves tests, the CLI and the
live runs.

## Known gaps

- **EUR accounts and IBANs**: the sandbox platform supports USD, USDC, USDT and USDB
  only, so the conformance suite's EUR scenarios cannot run here (see above).
- **US domestic payouts** (ACH, RTP, FedNow, wire to a routing and account number) and
  **US account details on `Account.t`** need a payments-core rail and destination and a
  non-IBAN address in banking-provider; until then `us_bank_details` exposes the deposit
  details and payouts go to IBANs, wallets and Lightning.
- **Cards** are not offered by this adapter; the card calls return an error.
- **Standing orders**: Grid has no scheduled payments.
- **Sandbox outcomes** are chosen when the customer or payee is created (name and account
  number suffixes); `simulate_kyc_decision` only confirms the decision Grid made and
  `simulate_transfer_outcome` returns an error.
- **`ping`** needs a webhook URL in the Grid dashboard; this adapter does not change
  platform settings.
- **SCA** is exercised on fixtures only (US customers get no challenge); passkey
  assertions cannot be passed through `confirm_sca`.
- **`totalBalance`** lagged settled payouts on the sandbox; balances report `balance` as
  available and posted with no holds.
- **Balance-change statements** answered 501 for customer accounts; statements are built
  from the newest transactions (`transactions_pages`).
- **Conversions done outside the adapter** show up as deposits into the bought currency.
- **Wallet networks** without a payments-core `Network.t` (Base, Arbitrum, Plasma,
  Spark) are left out of account addresses and cannot be paid.

## Used by

Nothing in the org yet.
