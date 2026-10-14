open! Core
open Banking_provider
open Payments_core

let event_id (tx : Grid_api.Transaction.t) =
  Event_id.of_string (sprintf "tx:%s:%s" tx.id tx.status)
;;

let rejection_reason (tx : Grid_api.Transaction.t) : Iso_reason.t option =
  match tx.failure_reason with
  | Some "ACCOUNT_INVALID" -> Some AC01
  | Some "ACCOUNT_CANNOT_RECEIVE" -> Some AC06
  | Some "COMPLIANCE_REJECTED" -> Some RR04
  | Some "LIMIT_EXCEEDED" -> Some AM02
  (* The payout partner refused without a finer reason; the money comes back. *)
  | Some "COUNTERPARTY_POST_TX_FAILED" -> Some MS03
  | _ -> None
;;

let outgoing_update (tx : Grid_api.Transaction.t) : Transfer_update.t option =
  match tx.status, tx.failure_reason with
  | ("CREATED" | "PENDING"), _ -> Some Submitted
  | "PENDING_AUTHORIZATION", _ -> None
  | "PROCESSING", _ -> Some Pending
  | "COMPLETED", _ -> Some Settled
  | "REFUNDED", _ | "FAILED", Some "PAYOUT_RETURNED" -> Some (Returned MS03)
  | "REJECTED", _ -> Some (Rejected (Option.value (rejection_reason tx) ~default:MS03))
  | "FAILED", Some "SCA_NOT_COMPLETED" -> Some (Failed Sca_failed)
  | "FAILED", Some "QUOTE_EXPIRED" | "EXPIRED", _ -> Some (Failed Expired)
  | "FAILED", reason ->
    (match rejection_reason tx with
     | Some r -> Some (Rejected r)
     | None ->
       Some
         (Failed (Provider_error (Option.value reason ~default:"failed without a reason"))))
  | _ -> None
;;

let network_of_grid n : Network.t option =
  match String.uppercase n with
  | "BASE" -> Some Base
  | "ARBITRUM" -> Some Arbitrum
  | "PLASMA" -> Some Plasma
  | "SPARK" -> Some Spark
  | "ETHEREUM" -> Some Ethereum
  | "POLYGON" -> Some Polygon
  | "SOLANA" -> Some Solana
  | "TRON" -> Some Tron
  | "BITCOIN" -> Some Bitcoin
  | _ -> None
;;

let rail (tx : Grid_api.Transaction.t) : Rail.t =
  match Option.bind tx.network ~f:network_of_grid, tx.payment_rail with
  | Some n, _ -> Onchain n
  | None, Some "LIGHTNING" -> Lightning
  | None, Some "SEPA" -> Sepa_credit
  | None, Some "SEPA_INSTANT" -> Sepa_instant
  (* Grid does not say how the receiver authorised an ACH entry; PPD (consumer) is the
     class it sends for individuals. *)
  | None, Some "ACH" -> Ach { sec = Ppd; same_day = false }
  | None, Some "ACH_SAME_DAY" -> Ach { sec = Ppd; same_day = true }
  | None, Some "RTP" -> Rtp
  | None, Some "WIRE" -> Fedwire
  | None, _ -> Intraledger
;;

let details (tx : Grid_api.Transaction.t) : Transfer.Details.t =
  match rail tx with
  | Onchain _ ->
    Onchain
      { travel_rule = None
      ; tx_hash = tx.tx_hash
      ; block_hash = None
      ; confirmations = 0
      ; finalized = String.equal tx.status "COMPLETED"
      }
  | Lightning -> Lightning { payment_hash = None; preimage = None }
  | Ach _ | Rtp | Fedwire -> Us_domestic Payments_core.Us_scheme.Details.empty
  | _ -> Intraledger
;;

let money_of (a : Grid_api.Amount.t option) ~what =
  match a with
  | Some a -> Grid_api.Amount.to_money a
  | None -> Or_error.error_s [%message "transaction without an amount" (what : string)]
;;

let fee (tx : Grid_api.Transaction.t) =
  let open Or_error.Let_syntax in
  let%bind sent = money_of tx.sent ~what:"sentAmount" in
  let currency = Money.Amount.currency sent in
  match tx.fees with
  | None | Some 0 -> Ok (Money.Amount.zero currency)
  | Some fees ->
    let%bind sent_decimals =
      Option.value_map tx.sent ~default:(Ok 2) ~f:(fun a -> Ok a.decimals)
    in
    Units.amount ~code:(Money.Currency.code currency) ~decimals:sent_decimals fees
;;

let incoming ~account (tx : Grid_api.Transaction.t) =
  let open Or_error.Let_syntax in
  let at =
    Grid_time.parse_or
      ~default:Time_ns.epoch
      (Option.first_some tx.updated_at tx.created_at)
  in
  let transfer = Event.incoming_transfer_id ~provider_ref:tx.id in
  let event suffix kind : Event.t =
    { id = Event_id.of_string (sprintf "tx:%s:%s" tx.id suffix); at; kind }
  in
  let update u = Event.Kind.Transfer { transfer; provider_ref = tx.id; update = u } in
  let deposit ~settled =
    let%map amount = money_of tx.received ~what:"receivedAmount" in
    event
      "in"
      (Incoming_transfer
         { account
         ; transfer
         ; provider_ref = tx.id
         ; rail = rail tx
         ; amount
         ; fee = Money.Amount.zero (Money.Amount.currency amount)
         ; from =
             External
               { name =
                   (match tx.source_type with
                    | Some "ACCOUNT" -> "account at the provider"
                    | Some "UMA_ADDRESS" -> "UMA sender"
                    | Some "REALTIME_FUNDING" -> "bank deposit"
                    | Some other -> other
                    | None -> "unknown")
               ; detail = Option.value tx.source_account_id ~default:""
               }
         ; reference = Option.value tx.description ~default:""
         ; details = details tx
         ; settled
         })
  in
  match tx.status with
  | "PENDING" | "PROCESSING" ->
    let%map d = deposit ~settled:false in
    [ d ]
  | "COMPLETED" ->
    let%map d = deposit ~settled:true in
    [ d; event tx.status (update Settled) ]
  | "FAILED" | "REJECTED" | "REFUNDED" ->
    (* After a completion the money came back (a return); before it, it never arrived. *)
    let u : Transfer_update.t =
      if Option.is_some tx.settled_at then Returned MS03 else Rejected MS03
    in
    Ok [ event tx.status (update u) ]
  | _ -> Ok []
;;
