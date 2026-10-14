(** Grid internal accounts as {!Banking_provider.Account.t}.

    A Grid customer gets one internal account per currency the platform supports (on the
    sandbox platform: USD, USDC, USDT and an embedded USDB wallet), created by Grid a
    moment after the customer. Each carries {e funding instructions}: how to pay into it.

    {v
      Grid funding instruction                       Account.Address
      EUR_ACCOUNT (iban)                             Iban
      ETHEREUM_WALLET, POLYGON_WALLET,
        SOLANA_WALLET, TRON_WALLET (address)         Crypto on that network
      USD_ACCOUNT (routing + account number)         none: see us_bank_details
      SWIFT_ACCOUNT, BASE/ARBITRUM/PLASMA/SPARK
        wallets                                      none: no payments-core type
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

(** US bank details of a USD account (ABA routing and account number), which
    {!Account.Address.t} cannot carry yet. *)
module Us_bank : sig
  type t =
    { routing_number : string
    ; account_number : string
    ; bank_name : string option
    ; reference : string option (** the memo a depositor must include *)
    ; rails : string list (** [ACH], [WIRE], [RTP], [FEDNOW] *)
    }
  [@@deriving sexp_of]
end

val us_bank_details : Grid_api.Internal_account.t -> Us_bank.t option
