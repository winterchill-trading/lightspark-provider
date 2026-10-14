open! Core
open! Async
open Banking_provider
open Lightspark_provider

let transactions () =
  Fixture.json "transactions.json"
  |> Yojson.Safe.Util.member "data"
  |> Yojson.Safe.Util.to_list
  |> List.map ~f:Grid_api.Transaction.of_json
;;

let%expect_test "a recorded customer history: conversion, payout, deposit" =
  List.iter (transactions ()) ~f:(fun tx ->
    print_s
      [%message
        ""
          ~type_:(tx.type_ : string)
          ~status:(tx.status : string)
          ~event_id:(Tx_map.event_id tx : Event_id.t)
          ~outgoing:(Tx_map.outgoing_update tx : Transfer_update.t option)
          ~rail:(Tx_map.rail tx : Payments_core.Rail.t)
          ~fee:(Tx_map.fee tx : Money.Amount.t Or_error.t)]);
  [%expect {|
    ((type_ INCOMING) (status COMPLETED)
     (event_id tx:Transaction:00000000-0000-0000-0000-000000000001:COMPLETED)
     (outgoing (Settled)) (rail Intraledger) (fee (Ok "0.00 USD")))
    ((type_ OUTGOING) (status COMPLETED)
     (event_id tx:Transaction:00000000-0000-0000-0000-000000000002:COMPLETED)
     (outgoing (Settled)) (rail Sepa_credit) (fee (Ok "0.60 USD")))
    ((type_ INCOMING) (status COMPLETED)
     (event_id tx:Transaction:00000000-0000-0000-0000-000000000003:COMPLETED)
     (outgoing (Settled)) (rail Intraledger)
     (fee (Error ("transaction without an amount" (what sentAmount)))))
    |}];
  return ()
;;

let%expect_test "incoming transactions become a deposit and its settlement" =
  let account = Refs.account ~customer_id:"Customer:c" ~account_id:"InternalAccount:a" in
  List.iter (transactions ()) ~f:(fun tx ->
    if String.equal tx.type_ "INCOMING"
    then
      List.iter (Tx_map.incoming ~account tx |> ok_exn) ~f:(fun (e : Event.t) ->
        print_s [%sexp (e.id : Event_id.t), (e.kind : Event.Kind.t)]));
  [%expect {|
    (tx:Transaction:00000000-0000-0000-0000-000000000001:in
     (Incoming_transfer (account Customer:c/InternalAccount:a)
      (transfer in:Transaction:00000000-0000-0000-0000-000000000001)
      (provider_ref Transaction:00000000-0000-0000-0000-000000000001)
      (rail Intraledger) (amount "10.000000 USDC") (fee "0.000000 USDC")
      (from
       (External (name "account at the provider")
        (detail InternalAccount:00000000-0000-0000-0000-000000000002)))
      (reference conversion) (details Intraledger) (settled true)))
    (tx:Transaction:00000000-0000-0000-0000-000000000001:COMPLETED
     (Transfer (transfer in:Transaction:00000000-0000-0000-0000-000000000001)
      (provider_ref Transaction:00000000-0000-0000-0000-000000000001)
      (update Settled)))
    (tx:Transaction:00000000-0000-0000-0000-000000000003:in
     (Incoming_transfer (account Customer:c/InternalAccount:a)
      (transfer in:Transaction:00000000-0000-0000-0000-000000000003)
      (provider_ref Transaction:00000000-0000-0000-0000-000000000003)
      (rail Intraledger) (amount "100.00 USD") (fee "0.00 USD")
      (from (External (name "UMA sender") (detail "")))
      (reference "sandbox deposit 1 20261014061935183914000Z")
      (details Intraledger) (settled true)))
    (tx:Transaction:00000000-0000-0000-0000-000000000003:COMPLETED
     (Transfer (transfer in:Transaction:00000000-0000-0000-0000-000000000003)
      (provider_ref Transaction:00000000-0000-0000-0000-000000000003)
      (update Settled)))
    |}];
  return ()
;;

let%expect_test "outgoing statuses and failure reasons" =
  let base = List.hd_exn (transactions ()) in
  List.iter
    [ "CREATED", None
    ; "PENDING", None
    ; "PENDING_AUTHORIZATION", None
    ; "PROCESSING", None
    ; "COMPLETED", None
    ; "FAILED", Some "PAYOUT_RETURNED"
    ; "FAILED", Some "ACCOUNT_INVALID"
    ; "FAILED", Some "ACCOUNT_CANNOT_RECEIVE"
    ; "FAILED", Some "COMPLIANCE_REJECTED"
    ; "FAILED", Some "LIMIT_EXCEEDED"
    ; "FAILED", Some "SCA_NOT_COMPLETED"
    ; "FAILED", Some "QUOTE_EXPIRED"
    ; "FAILED", Some "QUOTE_EXECUTION_FAILED"
    ; "FAILED", None
    ; "REJECTED", None
    ; "REFUNDED", None
    ; "EXPIRED", None
    ]
    ~f:(fun (status, failure_reason) ->
      let tx = { base with status; failure_reason } in
      print_s
        [%message
          status
            (failure_reason : string option)
            ~_:(Tx_map.outgoing_update tx : Transfer_update.t option)]);
  [%expect {|
    (CREATED (failure_reason ()) (Submitted))
    (PENDING (failure_reason ()) (Submitted))
    (PENDING_AUTHORIZATION (failure_reason ()) ())
    (PROCESSING (failure_reason ()) (Pending))
    (COMPLETED (failure_reason ()) (Settled))
    (FAILED (failure_reason (PAYOUT_RETURNED)) ((Returned MS03)))
    (FAILED (failure_reason (ACCOUNT_INVALID)) ((Rejected AC01)))
    (FAILED (failure_reason (ACCOUNT_CANNOT_RECEIVE)) ((Rejected AC06)))
    (FAILED (failure_reason (COMPLIANCE_REJECTED)) ((Rejected RR04)))
    (FAILED (failure_reason (LIMIT_EXCEEDED)) ((Rejected AM02)))
    (FAILED (failure_reason (SCA_NOT_COMPLETED)) ((Failed Sca_failed)))
    (FAILED (failure_reason (QUOTE_EXPIRED)) ((Failed Expired)))
    (FAILED (failure_reason (QUOTE_EXECUTION_FAILED))
     ((Failed (Provider_error QUOTE_EXECUTION_FAILED))))
    (FAILED (failure_reason ())
     ((Failed (Provider_error "failed without a reason"))))
    (REJECTED (failure_reason ()) ((Rejected MS03)))
    (REFUNDED (failure_reason ()) ((Returned MS03)))
    (EXPIRED (failure_reason ()) ((Failed Expired)))
    |}];
  return ()
;;

let%expect_test "an incoming transaction that failed after settling is a return" =
  let account = Refs.account ~customer_id:"Customer:c" ~account_id:"InternalAccount:a" in
  let tx =
    List.find_exn (transactions ()) ~f:(fun tx -> String.equal tx.type_ "INCOMING")
  in
  List.iter
    [ { tx with status = "PROCESSING"; settled_at = None }
    ; { tx with status = "FAILED" }
    ; { tx with status = "FAILED"; settled_at = None }
    ]
    ~f:(fun tx ->
      List.iter (Tx_map.incoming ~account tx |> ok_exn) ~f:(fun (e : Event.t) ->
        match e.kind with
        | Incoming_transfer { settled; _ } ->
          print_s [%message (e.id : Event_id.t) "deposit" (settled : bool)]
        | Transfer { update; _ } ->
          print_s [%message (e.id : Event_id.t) (update : Transfer_update.t)]
        | _ -> ()));
  [%expect {|
    ((e.id tx:Transaction:00000000-0000-0000-0000-000000000001:in) deposit
     (settled false))
    ((e.id tx:Transaction:00000000-0000-0000-0000-000000000001:FAILED)
     (update (Returned MS03)))
    ((e.id tx:Transaction:00000000-0000-0000-0000-000000000001:FAILED)
     (update (Rejected MS03)))
    |}];
  return ()
;;
