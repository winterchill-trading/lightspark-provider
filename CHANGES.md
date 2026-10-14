# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- `Adapter`: banking-provider's `Provider.S` and `Sandbox.S` over the Grid API:
  customers found or created by our id, KYC and contact verification, accounts opened by
  waiting for Grid's, balances, statements (balance changes, else transactions), fee
  quotes from exchange rates, payouts to IBANs, wallets, Lightning and own accounts with
  the receiving amount locked, SCA challenges on quotes, conversions as swaps, polling
  and signed webhook ingestion, sandbox deposits and test webhooks, and payee name
  checks (`verify_payee`) from the external account Grid creates for the payee.
- `Grid_api`: external accounts, quotes with payment rail, sender fields and SCA,
  authorization, execution, balance changes, contact verification, KYC links,
  transaction cancellation, exchange rates and test webhooks, with lenient views.
- `Store` with an in-memory implementation; `Refs`, `Units`, `Payee`, `Kyc_map`,
  `Account_map`, `Tx_map`, `Grid_time`.
- `lightspark-provider` CLI (`customer`, `fee`), `examples/quick_start.ml`, the live
  conformance runner and a USD walk.
