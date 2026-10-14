open! Core
open Banking_provider
open Payments_core

let currency (a : Grid_api.Internal_account.t) =
  Units.currency ~code:a.balance.code ~decimals:a.balance.decimals
;;

let status s : Ledger.Account_status.t =
  match s with
  | "CLOSED" | "FAILED" -> Closed
  | "FROZEN" | "SUSPENDED" | "INACTIVE" -> Frozen
  | _ -> Open
;;

let network_of_wallet = function
  | "ETHEREUM_WALLET" -> Some Network.Ethereum
  | "POLYGON_WALLET" -> Some Polygon
  | "SOLANA_WALLET" -> Some Solana
  | "TRON_WALLET" -> Some Tron
  | _ -> None
;;

let addresses (instructions : Grid_api.Funding_instruction.t list) =
  List.filter_map instructions ~f:(fun i ->
    match i.account_type, i.iban, i.address with
    | "EUR_ACCOUNT", Some iban, _ ->
      (match Iban.of_string iban with
       | Ok iban ->
         let bic = Option.bind i.swift_code ~f:(fun b -> Result.ok (Bic.of_string b)) in
         Some (Account.Address.Iban { iban; bic })
       | Error _ -> None)
    | wallet, _, Some address ->
      Option.bind (network_of_wallet wallet) ~f:(fun network ->
        match Crypto_address.create network address with
        | Ok address -> Some (Account.Address.Crypto { address; memo = None })
        | Error _ -> None)
    | _ -> None)
;;

let account ~customer_id (a : Grid_api.Internal_account.t) =
  let open Or_error.Let_syntax in
  let%map currency = currency a in
  { Account.id = Refs.account ~customer_id ~account_id:a.id
  ; customer = Refs.customer customer_id
  ; currency
  ; status = status a.status
  ; addresses = addresses a.funding
  ; opened_at = Grid_time.parse_or ~default:Time_ns.epoch (Some a.created_at)
  }
;;

let balance account (a : Grid_api.Internal_account.t) ~at =
  let open Or_error.Let_syntax in
  let%bind available = Grid_api.Amount.to_money a.balance in
  let%bind posted =
    match a.total_balance with
    | Some total -> Grid_api.Amount.to_money total
    | None -> Ok available
  in
  let%bind held = Money.Amount.sub posted available in
  (* A total below the spendable balance would be a Grid inconsistency; report no hold
     rather than a negative one. *)
  let held =
    if Money.Amount.is_negative held then Money.Amount.zero (Money.Amount.currency held) else held
  in
  let%map posted = Money.Amount.add available held in
  { Account.Balance.account; available; held; posted; as_of = at }
;;

module Us_bank = struct
  type t =
    { routing_number : string
    ; account_number : string
    ; bank_name : string option
    ; reference : string option
    ; rails : string list
    }
  [@@deriving sexp_of]
end

let us_bank_details (a : Grid_api.Internal_account.t) =
  List.find_map a.funding ~f:(fun i ->
    match i.account_type, i.routing_number, i.account_number with
    | "USD_ACCOUNT", Some routing_number, Some account_number ->
      Some
        { Us_bank.routing_number
        ; account_number
        ; bank_name = i.bank_name
        ; reference = i.reference
        ; rails = i.payment_rails
        }
    | _ -> None)
;;
