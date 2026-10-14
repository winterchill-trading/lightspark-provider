(** Grid internal accounts as {!Banking_provider.Account.t}.

    A Grid customer gets one internal account per currency the platform supports (on the
    sandbox platform: USD, USDC, USDT and an embedded USDB wallet), created by Grid a
    moment after the customer. Each carries {e funding instructions}: how to pay into it.

    {v
      Grid funding instruction                       Account.Address
      EUR_ACCOUNT (iban)                             Iban
      ETHEREUM, POLYGON, SOLANA, TRON, BASE,
        ARBITRUM, PLASMA, SPARK _WALLET (address)    Crypto on that network
      USD_ACCOUNT (routing + account number)         Us_account (checking), when the
                                                       routing number passes the ABA
                                                       check digit
      SWIFT_ACCOUNT                                  none: no payments-core type
    v}

    Balances: Grid's [balance] is what can be spent; [available = posted = balance] and
    [held] is zero. Grid documents [totalBalance] as the balance including pending and
    held funds, but on the sandbox it stayed at the deposited total after settled payouts
    and conversions, so it is not used. *)

open! Core
open Banking_provider

val currency : Grid_api.Internal_account.t -> Money.Currency.t Or_error.t

(** [ACTIVE] and anything unknown are [Open]; [FROZEN], [SUSPENDED] and [INACTIVE] are
    [Frozen]; [CLOSED] and [FAILED] (an account Grid could not open) are [Closed]. *)
val status : string -> Ledger.Account_status.t

val addresses : Grid_api.Funding_instruction.t list -> Account.Address.t list
val account : customer_id:string -> Grid_api.Internal_account.t -> Account.t Or_error.t

val balance
  :  Account_ref.t
  -> Grid_api.Internal_account.t
  -> at:Time_ns.t
  -> Account.Balance.t Or_error.t
