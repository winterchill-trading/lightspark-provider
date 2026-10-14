(** Where a transfer goes, in Grid terms.

    Grid pays out to an {e external account} it holds for the customer: a bank account in
    the payee's currency, a wallet on a network, or a Lightning destination. This module
    turns a payments-core beneficiary into that account's [accountInfo] object, the
    currency Grid should deliver and the payment rail to ask for.

    {v
      Beneficiary destination           rail             Grid accountInfo           currency
      Bank_account (IBAN)               Sepa_credit      EUR_ACCOUNT, rail SEPA          EUR
      Bank_account (IBAN)               Sepa_instant     EUR_ACCOUNT, SEPA_INSTANT       EUR
      Us_account                        Ach              USD_ACCOUNT, ACH or
                                                           ACH_SAME_DAY                  USD
      Us_account                        Rtp / Fedwire    USD_ACCOUNT, RTP / WIRE         USD
      Crypto on Ethereum/Polygon/
        Solana/Tron/Base/Arbitrum/
        Plasma/Spark                    Onchain n        <NETWORK>_WALLET           USDC/USDT
      Lightning invoice or address      Lightning        LIGHTNING                       BTC
      Internal (an account reference)   Intraledger      none: the internal account   same
    v}

    Bitcoin on-chain addresses and LNURL strings have no Grid account type; an IBAN in
    another currency than EUR has no SEPA payout, a US account no payout in another
    currency than USD. FedNow has no payments-core rail. *)

open! Core
open Payments_core

type t =
  | External of
      { currency : string (** what the payee receives *)
      ; account_info : (Yojson.Safe.t[@sexp.opaque])
      ; payment_rail : string option
      ; platform_account_id : string (** our beneficiary id, kept by Grid *)
      }
  | Internal of { account_id : string (** a Grid internal account *) }
[@@deriving sexp_of]

(** [payee_country] fills the beneficiary's country of residence where Grid asks for it
    and the destination does not say (wallets); an IBAN gives its own country. *)
val of_transfer : Transfer.t -> payee_country:string -> t Or_error.t

(** The [EUR_ACCOUNT] (IBAN) or [USD_ACCOUNT] (routing and account number) external
    account for a bank beneficiary; [None] for other destinations. *)
val bank_account : Beneficiary.t -> payment_rail:string option -> t option

(** Grid's [<NETWORK>_WALLET] account type for a network, if it has one. *)
val wallet_type : Network.t -> string option

(** Grid's payment rail for a US rail: [ACH], [ACH_SAME_DAY], [RTP], [WIRE]. *)
val us_rail : Rail.t -> string option
