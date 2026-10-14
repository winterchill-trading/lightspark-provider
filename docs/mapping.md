# Mapping: banking-provider to the Grid API

How each `Provider.S` and `Sandbox.S` operation is carried out with the Lightspark Grid
API (version `2025-10-13`, through `lightspark-client` and this repo's `Grid_api`), how
Grid's webhooks and transactions become `Event.t`, and what has no Grid counterpart.
Paths are relative to `https://api.lightspark.com/grid/2025-10-13`.

## Ids

| Ours                       | Grid                                            | Where the link lives |
| -------------------------- | ----------------------------------------------- | -------------------- |
| `Customer_ref.t`           | customer id (`Customer:<uuid>`)                 | the ref itself |
| `Kyc_core.Customer_id.t`   | `platformCustomerId` on the customer            | Grid (`GET /customers?platformCustomerId=`) |
| `Account_ref.t`            | `<customer id>/<internal account id>` (`Refs`)  | the ref itself (Grid has no read of one internal account) |
| `Beneficiary.Id.t`         | `platformAccountId` on the external account     | Grid (listed per customer) |
| `Transfer.Id.t`            | the quote's `Idempotency-Key`; quote id, then transaction id | `Store.Transfer_record` |
| `Sca.Id.t`                 | `grid:<quote id>:<challenge id>`                | `Store.Challenge_record` |
| `Swap.Id.t`                | `swp-<ns>-<n>`, the quote's `Idempotency-Key`   | `Store.Swap_record` |
| `Event_id.t`               | derived from Grid data (see Events)             | none: poll and webhook derive the same id |

Every create carries an `Idempotency-Key` (customer: `customer-<our id>`; external
account: `<customer>:<beneficiary>:<currency>`; quote: our transfer or swap id; quote
execution: `<id>:execute`), so a resend after a lost response returns Grid's original
object. The store is needed only for "which quote is this transfer".

## Operations

| `Provider.S`            | Grid endpoint(s)                                                          | Notes |
| ----------------------- | ------------------------------------------------------------------------- | ----- |
| `name`                  | none                                                                      | `"lightspark"` |
| `create_customer`       | `GET /customers?platformCustomerId=`, else `POST /customers`              | individual; name, birth date, nationality, address, a deliverable e-mail (`Config.email_for`) |
| `update_customer`       | `GET /customers/{id}`, `PATCH /customers/{id}`                            | name, birth date, nationality, address; e-mail and phone are left alone (Grid needs a signed retry flow for them on embedded wallets) |
| `start_verification`    | Email: `POST /customers/{id}/verify-email`; Mobile: `.../verify-phone`; document, liveness: `POST /customers/{id}/kyc-link` | `Code_sent`, or `Hosted` with the link's SDK token (else its URL) |
| `complete_verification` | `.../verify-email/confirm`, `.../verify-phone/confirm`; others read the customer | a refused code is `Failed "wrong code"` |
| `kyc_status`            | `GET /customers/{id}`                                                     | publishes the change as events |
| `open_account`          | `GET /config` (cached), `GET /customers/internal-accounts?customerId=` (polled) | Grid opens one account per supported currency itself; opening is waiting up to `provisioning_timeout`; a currency the platform does not hold is an error |
| `accounts`              | `GET /customers/internal-accounts?customerId=` (all pages)                | currencies `money` cannot represent are skipped |
| `balance`               | the same list                                                             | `available = posted = balance`, `held = 0` (see api-notes) |
| `enrich_account`        | the same list                                                             | addresses come with the account (funding instructions) |
| `statement`             | `GET /internal-accounts/{id}/balance-changes`; on 501 `GET /transactions?customerId=` | lines walk back from the current balance |
| `quote_fee`             | `GET /exchange-rates?sourceCurrency=&destinationCurrency=` twice (rate, then fees for the size) | same currency: zero (Grid publishes no fee); the fee and total are in the account's currency |
| `initiate_transfer`     | `GET`/`POST /customers/external-accounts`, `POST /quotes` (receiving amount locked), `POST /quotes/{id}/execute`, `GET /transactions/{id}` | an SCA region quote answers `PENDING_AUTHORIZATION`: `Challenge` |
| `transfer`              | `GET /transactions/{id}`                                                  | |
| `cancel_transfer`       | `POST /transactions/{id}/cancel`                                          | a quote never executed lapses on its own |
| `confirm_sca`           | `POST /quotes/{id}/authorize`, then `POST /quotes/{id}/execute`           | wrong code: `Wrong_code`, five attempts counted locally |
| `verify_payee`          | `GET`/`POST /customers/external-accounts` (the `EUR_ACCOUNT` for the IBAN) | Grid checks the name when it creates the account: `MATCHED` Match, `PARTIAL_MATCH` Close_match (no suggested name), `NOT_MATCHED` No_match, `UNSUPPORTED`/`CHECKED_BY_RECEIVING_FI` Not_possible, `PENDING` Unavailable, a 400 Account_not_found; other destinations Not_possible |
| `quote_swap`            | `POST /quotes` between two internal accounts of one customer (sending amount locked) | the price comes from the amounts, not Grid's float rate |
| `execute_swap`          | `POST /quotes/{id}/execute`, `GET /transactions/{id}`                     | result as `Swap_executed` / `Swap_failed` |
| `issue_virtual_card`, `card`, `cards`, `set_card_status`, `set_card_limits`, `card_details_token` | none | error: cards are out of scope for this adapter |
| `create_standing_order`, `cancel_standing_order` | none                                             | error: Grid has no scheduled payments |
| `events`                | polling `GET /customers/{id}` and `GET /transactions?customerId=`         | only while subscribed |
| `ingest_webhook`        | none (verifies `X-Grid-Signature`, P-256, with the platform key)          | refuses everything when no key is configured |

| `Sandbox.S`                 | Grid endpoint(s)                                                  | Notes |
| --------------------------- | ----------------------------------------------------------------- | ----- |
| `simulate_deposit`          | `POST /sandbox/internal-accounts/{id}/fund`, then `GET /transactions` (polled) | in the account's currency; found again by its description; reported on the `Intraledger` rail whatever rail is asked |
| `simulate_kyc_decision`     | `GET /customers/{id}`                                             | Grid decides at creation by the name's last three characters; succeeds only when the decision matches |
| `simulate_card_auth`        | none                                                              | error |
| `simulate_transfer_outcome` | none                                                              | error: outcomes are chosen by the payee account's last three digits |
| `simulate_payee_check`      | none                                                              | error: the answer is fixed by the account number's last three digits (102-107) |
| `ping`                      | `POST /webhooks/test`                                             | publishes `Ping` once Grid reports a delivery; fails while the platform has no webhook URL |

Every money-moving write (`POST /customers`, external accounts, quotes, execution) first
passes lightspark-client's sandbox check unless the config is `Live`, and the
`Sandbox.S` calls refuse `Live` configs.

## Events

Webhook type (and transaction status seen by the poller) to `Event.Kind.t`:

| Grid                                                  | Event                                 | Event id |
| ----------------------------------------------------- | ------------------------------------- | -------- |
| `CUSTOMER.KYC_*` (and each customer poll)             | `Kyc_step` per changed step, then `Kyc` transitions | `kyc:<customer>:step:<Step>:<State>`, `kyc:<customer>:<From>:<Transition>` |
| `OUTGOING_PAYMENT.*`: `CREATED`, `PENDING`            | `Transfer Submitted`                  | `tx:<transaction id>:<STATUS>` |
| `PROCESSING`                                          | `Transfer Pending`                    | same |
| `COMPLETED`                                           | `Transfer Settled`                    | same |
| `FAILED` `PAYOUT_RETURNED`, `REFUNDED`                | `Transfer (Returned MS03)`            | same |
| `FAILED` `ACCOUNT_INVALID` / `ACCOUNT_CANNOT_RECEIVE` / `COMPLIANCE_REJECTED` / `LIMIT_EXCEEDED` / `COUNTERPARTY_POST_TX_FAILED` | `Transfer (Rejected AC01 / AC06 / RR04 / AM02 / MS03)` | same |
| `REJECTED`                                            | `Transfer (Rejected MS03)`            | same |
| `FAILED` `SCA_NOT_COMPLETED`                          | `Transfer (Failed Sca_failed)`        | same |
| `FAILED` `QUOTE_EXPIRED`, `EXPIRED`                   | `Transfer (Failed Expired)`           | same |
| `FAILED` other                                        | `Transfer (Failed (Provider_error <reason>))` | same |
| `INCOMING_PAYMENT.*` `PENDING`, `PROCESSING`          | `Incoming_transfer` (not settled)     | `tx:<id>:in` |
| `INCOMING_PAYMENT.COMPLETED`                          | `Incoming_transfer` (settled) and `Transfer Settled` | `tx:<id>:in`, `tx:<id>:COMPLETED` |
| `INCOMING_PAYMENT.FAILED`                             | `Transfer (Returned MS03)` after settlement, else `Rejected MS03` | `tx:<id>:FAILED` |
| a transaction of one of our swap quotes               | `Swap_executed` / `Swap_failed`       | `swap:<id>:executed`, `swap:<id>:failed` |
| creating an external account with a name check       | `Payee_check` (`MATCHED`, `PARTIAL_MATCH`, `NOT_MATCHED`, `UNSUPPORTED`/`CHECKED_BY_RECEIVING_FI`) | `payee:<external account>:<status>` |
| `TEST`                                                | `Ping`                                | `ping:<delivery id>` |
| quote or execution refused for funds                  | `Transfer (Failed Insufficient_funds)` | `failed:<transfer id>` |
| execution accepted                                    | `Transfer Submitted`                  | `submitted:<transfer id>` |
| `cancel_transfer`                                     | `Transfer Cancelled`                  | `cancel:<transfer id>` |
| `INTERNAL_ACCOUNT.*`, `EXTERNAL_ACCOUNT.*`, `VERIFICATION.*`, cards, agents | nothing (accepted) | |

Grid sends no ISO 20022 reason codes; `MS03` stands in where none of the above fits.

## Currencies

| Grid code | `Money.Currency`        | Grid decimals | Ours |
| --------- | ----------------------- | ------------- | ---- |
| USD       | `usd`                   | 2             | 2    |
| USDC      | `usdc` (untagged)       | 6             | 6    |
| USDT      | `usdt` (untagged)       | 6             | 6    |
| USDB      | registered on first use | 6             | 6    |
| EUR and other payout currencies | `money`'s registry, else registered with Grid's decimals | per currency | same |
| BTC (Lightning payouts) | `btc`     | 8             | 8    |

An amount with more digits than the target unit is refused, never rounded.

## Rails and payees

| Draft rail and destination                   | Grid external account (`accountType`) | Payment rail | Payee receives |
| -------------------------------------------- | ------------------------------------- | ------------ | -------------- |
| `Sepa_credit`, IBAN                          | `EUR_ACCOUNT`                         | `SEPA`       | EUR |
| `Sepa_instant`, IBAN                         | `EUR_ACCOUNT`                         | `SEPA_INSTANT` | EUR |
| `Onchain Ethereum / Polygon / Solana / Tron` | `<NETWORK>_WALLET`                    | Grid's choice | the draft's stablecoin |
| `Lightning`, invoice or Lightning address    | `LIGHTNING`                           | Grid's choice | BTC |
| `Intraledger`, an account reference          | none: the internal account directly   | none         | same currency |

Incoming transactions are reported on `Onchain` when Grid gives a hash or a network,
`Sepa_credit`/`Sepa_instant`/`Lightning` when its rail says so, and `Intraledger`
otherwise (US bank rails, sandbox credits, conversions).

## KYC

| Grid `kycStatus` | `Kyc_core.Status.t` | Identity_document, Liveness |
| ---------------- | ------------------- | --------------------------- |
| `UNVERIFIED`     | `Created`           | `Pending` |
| `PENDING`        | `Verifying`         | `Sent` |
| `APPROVED`       | `Approved`          | `Verified` |
| `REJECTED`       | `Rejected`          | `Failed` |
| `HOLD`           | `Needs_resubmission` (identity fields) | `Failed "on hold"` |

`contactVerification.email` / `.phone` (only where the jurisdiction asks): `PENDING` is
`Sent`, `VERIFIED` is `Verified`; absent leaves the step `Pending`.

## SCA

Grid issues a challenge on a quote only for customers in SCA regions (the EU). Factors
`SMS_OTP` and `TOTP` map to `Otp` and `Totp`, `PASSKEY` to `Passkey`. Grid may chain
challenges (a conversion, then the payout); after an accepted one that leaves the quote
in `PENDING_AUTHORIZATION`, a resend of `initiate_transfer` hands out the next. Grid
does not report remaining attempts; five are counted locally. Passkey assertions are
not carried by `confirm_sca` (it takes a code).

## Gaps

- **Cards**: not offered here (Grid has card endpoints; out of this adapter's scope).
- **US domestic payouts** (ACH, RTP, FedNow, wire to a routing and account number): no
  payments-core rail or beneficiary destination for them yet; `us_bank_details` gives
  the deposit side only.
- **Non-IBAN account details** on `Account.t`: USD routing and account numbers are not
  representable; Base, Arbitrum, Plasma and Spark wallet addresses neither (no
  `Network.t`).
- **Standing orders**: none at Grid.
- **Sandbox**: KYC outcomes and payout outcomes are fixed at creation by magic
  suffixes; there is no call to change them afterwards. `ping` needs a webhook URL set
  in the dashboard, which this adapter never changes.
- **Conversions done outside the adapter** (or after a restart without a persisted
  store) are reported as a deposit into the bought currency's account; the sold side is
  not reported.
