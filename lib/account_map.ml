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
  | "BASE_WALLET" -> Some Base
  | "ARBITRUM_WALLET" -> Some Arbitrum
  | "PLASMA_WALLET" -> Some Plasma
  | "SPARK_WALLET" -> Some Spark
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
    | "USD_ACCOUNT", _, _ ->
      (* Grid's USD accounts are checking accounts at its partner bank. *)
      (match i.routing_number, i.account_number with
       | Some routing, Some account_number ->
         (match Aba.of_string routing with
          (* The sandbox hands out random routing numbers; about nine in ten fail the ABA
             check digit (measured 2026-10-14) and cannot be represented. *)
          | Error _ -> None
          | Ok routing ->
            Us_account.create ~routing ~account_number ()
            |> Result.ok
            |> Option.map ~f:(fun a -> Account.Address.Us_account a))
       | _ -> None)
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
  (* [totalBalance] is not used: on the sandbox it stayed at the deposited total after
     settled payouts and conversions (measured 2026-10-14), so it cannot stand for the
     posted balance. *)
  let%map.Or_error available = Grid_api.Amount.to_money a.balance in
  { Account.Balance.account
  ; available
  ; held = Money.Amount.zero (Money.Amount.currency available)
  ; posted = available
  ; as_of = at
  }
;;
