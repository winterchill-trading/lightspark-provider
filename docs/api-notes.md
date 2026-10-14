# Grid API notes for the adapter

What building `Provider.S` over the Grid API taught us (October 2026), beyond the client
notes in [lightspark-client](https://github.com/winterchill-trading/lightspark-client/blob/main/docs/api-notes.md).

## Auth, versioning, idempotency

- HTTP Basic with the Grid token; the version is the date in the path (`2025-10-13`).
- Every create takes `Idempotency-Key`; a replay returns the original object, another
  body under the same key is 409. Quotes, quote executions, customers and external
  accounts are all keyed by our own ids, so the adapter never needs a lookup before a
  resend, except for customers, which it finds by `platformCustomerId` first because a
  different key would create a second customer.
- Grid stores our ids: `platformCustomerId` on customers and `platformAccountId` on
  external accounts. Quotes and transactions have no field for an external id other
  than `description`, so transfers keep a small store.

## Pagination and rate limits

- `limit` (max 100) and `cursor`; `hasMore` and `nextCursor`. The poller reads the
  newest pages of `GET /transactions?customerId=` only (`transactions_pages`, default 3).
- No rate-limit headers on normal responses; 429 may carry `Retry-After`, which
  lightspark-client's retry honours.

## Customers and KYC

- On the regulated sandbox platform a customer is `APPROVED` at creation unless the full
  name ends in `001` (pending), `002` (rejected) or `003` (unverified). The decision
  cannot be changed afterwards, so `simulate_kyc_decision` can only confirm it.
- `contactVerification` is absent for US customers; the e-mail and phone steps stay
  `Pending` for them.
- The e-mail must be deliverable (the platform has embedded wallets);
  `hello+sandbox-<id>@winterchill.xyz` plus-addresses work.

## Accounts and balances

- Four internal accounts appear a moment after the customer: USD (`INTERNAL_FIAT`),
  USDC and USDT (`INTERNAL_CRYPTO`) and USDB (`EMBEDDED_WALLET`). Each carries funding
  instructions: a US bank account (ABA routing and account number, rails ACH, wire, RTP,
  FedNow) plus a SWIFT account for USD, wallet addresses on several chains for the
  stablecoins.
- `GET /internal-accounts/{id}` is not in the API; read the customer's list.
- **`totalBalance` lags**: after a settled payout and a conversion the USD account's
  `balance` dropped from 100.00 to 55.53 while `totalBalance` stayed at 100.00
  (measured 2026-10-14). The adapter reports `balance` as both available and posted.
- `GET /internal-accounts/{id}/balance-changes` answered `501 NOT_IMPLEMENTED`
  ("Balance-change statements are not supported for this account") for a customer's USD
  account; statements fall back to the transaction list.

## Payouts and FX

- A payout is a quote from the internal account to an external account (created once per
  payee), then an execution. Lock the receiving side to pay an exact amount; the quote's
  `feesIncluded` and `totalSendingAmount` are in the sending currency.
- USD to EUR quotes fail with `400 MISSING_MANDATORY_USER_INFO` ("PURPOSE_OF_PAYMENT
  must not be empty") until `senderCustomerInfo.PURPOSE_OF_PAYMENT` is sent; the adapter
  sends `Config.purpose_of_payment` (default `GOODS_OR_SERVICES`).
- `GET /exchange-rates` gives the rate in sending smallest units per receiving smallest
  unit (USD to EUR 1.1177, USD to USDC 0.0000998) and the fees for the `sendingAmount`
  asked (fixed plus variable: 0.54 + 0.17 USD for 100 USD to EUR). Ask once for the rate
  and again with the computed sending amount for the fee.
- Measured on the sandbox (2026-10-14): EUR 30.00 by SEPA cost 34.36 to 34.47 USD
  including a 0.60 USD fee; the transaction went `PENDING` (answer to the execution),
  `PROCESSING`, `COMPLETED` within about a minute. A USDC 1.00 payout to an Ethereum
  address completed with no fee. A USD to USDC conversion between the customer's own
  accounts priced 1:1 with no fee and completed in about two seconds; its transaction
  is `INCOMING` on the USDC account with the USD account as source.
- Magic suffixes: the documented quote table (002 execution failed, 003 slow, 005
  returned, 010-013 granular reasons) is keyed on the destination's account number. An
  IBAN ending in `011` failed with `COUNTERPARTY_POST_TX_FAILED` rather than
  `ACCOUNT_INVALID`, and the debit was refunded at once.
- External accounts report `beneficiaryVerificationStatus`; SEPA accounts came back
  `UNSUPPORTED`.

## US rails (measured 2026-10-14)

- Payouts to a `USD_ACCOUNT` external account (routing number, account number, checking
  or savings) over `ACH` cost 0.05 USD and over `RTP` 0.50 USD on the sandbox; both
  settled within a minute (`PENDING`, `PROCESSING`, `COMPLETED`).
- `WIRE` is refused with `400 INVALID_INPUT` ("Beneficiary postal address is required for
  WIRE transfers").
- `GET /exchange-rates` has no USD to USD rates (`INVALID_INPUT`), so a domestic fee is
  only known from the quote.
- Sandbox USD accounts get random routing numbers: 4 of the 25 on the platform passed the
  ABA check digit.

## SCA

- Quotes for customers in SCA regions answer `PENDING_AUTHORIZATION` with an
  `scaChallenge`; `POST /quotes/{id}/authorize` takes the code (sandbox `123456`), and a
  quote may need several authorizations in turn. US sandbox customers never see one, so
  the adapter's challenge path is tested on fixtures shaped like the documentation.

## Webhooks

- One URL per platform, set in the dashboard; deliveries are signed with ECDSA P-256 over
  SHA-256 of the raw body (`X-Grid-Signature`, bare base64 or `{"v":"1","s":...}`), the
  platform's public key from the dashboard. `id` is the delivery id.
- `POST /webhooks/test` answers `400 WEBHOOK_ENDPOINT_NOT_SET` while no URL is set. The
  adapter never sets one (account settings are left alone), so the ping is untested live.

## Sandbox

- No explicit sandbox flag: lightspark-client trusts a `GET /config` whose UMA domain
  contains `sandbox`.
- `POST /sandbox/internal-accounts/{id}/fund` credits at once and records an `INCOMING`
  `COMPLETED` transaction with our `description` and an `UMA_ADDRESS` source; it answers
  with the account, not the transaction, so the adapter finds the transaction by its
  description.
- Cross-customer transfers are disabled on this platform; UMA sends fail (see the client
  notes).
