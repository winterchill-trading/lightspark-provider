open! Core
open! Async
open Banking_provider
open Payments_core
open Lightspark_provider
module Lc = Lightspark_client

let r = Fixture.response
let config_route = ("GET", "/config"), [ r "config.json" ]
let customer = Refs.customer "Customer:00000000-0000-0000-0000-000000000001"

let usd_account =
  Refs.account
    ~customer_id:"Customer:00000000-0000-0000-0000-000000000001"
    ~account_id:"InternalAccount:00000000-0000-0000-0000-000000000001"
;;

let adapter ?verbose ?store ?webhook_public_key routes =
  Adapter.create
    ~config:
      { Adapter.Config.default with
        webhook_public_key
      ; (* The poller's first round runs at subscription, before any customer is known; a
           long interval keeps it from interleaving with the test's calls. *)
        poll_interval = Time_ns.Span.hour
      ; provisioning_timeout = Time_ns.Span.of_ms 50.
      }
    ?store
    (Fixture.api ?verbose (config_route :: routes))
;;

(* What the subscription received so far. *)
let drain events =
  let seen =
    match Pipe.read_now' events with
    | `Ok q -> q
    | `Eof | `Nothing_available -> Queue.create ()
  in
  Pipe.close_read events;
  seen
;;

let print_event (e : Event.t) =
  print_s [%message (e.id : Event_id.t) ~_:(e.kind : Event.Kind.t)]
;;

(* {2 Payouts} *)

let eur s = Money.Amount.of_decimal_string Money.Currency.eur s |> ok_exn

let sepa_draft ?(id = "tr-1") amount =
  let iban = "DE89370400440532013000" in
  let beneficiary =
    Beneficiary.create
      ~id:(Beneficiary.Id.of_string "ben-1")
      ~owner:(Customer_ref.to_string customer)
      ~name:"Erika Payee"
      ~rail:Sepa_credit
      ~now:Time_ns.epoch
      iban
    |> ok_exn
  in
  let party name =
    { Iso20022.Party.name
    ; iban = Iban.of_string iban |> ok_exn
    ; bic = None
    ; address = None
    }
  in
  Transfer.draft
    ~id:(Transfer.Id.of_string id)
    ~rail:Sepa_credit
    ~account:(Ledger.Account_id.of_string "app:1")
    ~beneficiary
    ~amount
    ~reference:"invoice 1"
    ~details:
      (Sepa
         (Sepa.Details.create
            ~payment_id:(Iso20022.Payment_id.create ~end_to_end_id:id () |> ok_exn)
            ~debtor:(party "Ada Sandbox")
            ~creditor:(party "Erika Payee")
            ()))
    ~now:Time_ns.epoch
    ()
  |> ok_exn
;;

let payout_routes ~quote ~after_quote =
  [ ("GET", "/customers/external-accounts"), [ r "empty-page.json" ]
  ; ("POST", "/customers/external-accounts"), [ r "external-account.json" ]
  ; ("POST", "/quotes"), [ quote ]
  ]
  @ after_quote
  @ [ ( ("GET", "/transactions/Transaction:00000000-0000-0000-0000-000000000001")
      , [ r "transaction-payout.json" ] )
    ]
;;

let show_started = function
  | Error e -> print_s [%message "error" (e : Error.t)]
  | Ok (Sca_challenge.Or_challenge.Done (i : Transfer_info.t)) ->
    print_s
      [%message
        "done" ~status:(i.status : Transfer.Status.t) ~fee:(i.fee : Money.Amount.t)]
  | Ok (Challenge c) ->
    print_s
      [%message
        "challenge"
          ~factors:(c.factors : Sca.Kind.t list)
          ~attempts_left:(c.attempts_left : int)
          ~purpose:(c.purpose : Sca_challenge.Purpose.t)]
;;

let%expect_test "a cross-border payout without SCA: quote, execute, settled" =
  let t =
    adapter
      ~verbose:true
      (payout_routes
         ~quote:(r "quote-sepa.json")
         ~after_quote:
           [ ( ("POST", "/quotes/Quote:00000000-0000-0000-0000-000000000001/execute")
             , [ r "quote-sepa.json" ] )
           ])
  in
  let events = Adapter.events t in
  let draft = sepa_draft (eur "30.00") in
  let%bind started = Adapter.initiate_transfer t ~from:usd_account draft in
  show_started started;
  (* A resend reports the first call's transfer and creates nothing. *)
  let%bind again = Adapter.initiate_transfer t ~from:usd_account draft in
  show_started again;
  let%map seen = return (drain events) in
  Queue.iter seen ~f:print_event;
  [%expect
    {|
    GET /grid/2025-10-13/customers/external-accounts
    GET /grid/2025-10-13/config
    POST /grid/2025-10-13/customers/external-accounts
    POST /grid/2025-10-13/quotes
    POST /grid/2025-10-13/quotes/Quote:00000000-0000-0000-0000-000000000001/execute
    GET /grid/2025-10-13/transactions/Transaction:00000000-0000-0000-0000-000000000001
    (done (status Settled) (fee "0.60 USD"))
    GET /grid/2025-10-13/transactions/Transaction:00000000-0000-0000-0000-000000000001
    (done (status Settled) (fee "0.60 USD"))
    ((e.id
      payee:ExternalAccount:00000000-0000-0000-0000-000000000001:UNSUPPORTED)
     (Payee_check (beneficiary ben-1) (result Not_possible)))
    ((e.id submitted:tr-1)
     (Transfer (transfer tr-1)
      (provider_ref Transaction:00000000-0000-0000-0000-000000000001)
      (update Submitted)))
    ((e.id tx:Transaction:00000000-0000-0000-0000-000000000001:COMPLETED)
     (Transfer (transfer tr-1)
      (provider_ref Transaction:00000000-0000-0000-0000-000000000001)
      (update Settled)))
    |}]
;;

let%expect_test "a payout behind SCA: wrong code, then accepted, then executed" =
  let t =
    adapter
      (payout_routes
         ~quote:(r "quote-sca.json")
         ~after_quote:
           [ ( ("POST", "/quotes/Quote:00000000-0000-0000-0000-000000000007/authorize")
             , [ r ~status:400 "error-sca-code.json"; r "quote-sca-authorized.json" ] )
           ; ( ("POST", "/quotes/Quote:00000000-0000-0000-0000-000000000007/execute")
             , [ r "quote-sca-executed.json" ] )
           ; ( ("GET", "/transactions/Transaction:00000000-0000-0000-0000-000000000007")
             , [ r "transaction-payout.json" ] )
           ])
  in
  let draft = sepa_draft (eur "30.00") in
  let%bind started = Adapter.initiate_transfer t ~from:usd_account draft in
  show_started started;
  let challenge =
    match started with
    | Ok (Challenge c) -> c
    | _ -> failwith "expected a challenge"
  in
  let confirm code =
    let%map result =
      Adapter.confirm_sca t challenge.id ~code:(Sensitive.of_string code)
    in
    print_s [%sexp (result : Sca_challenge.Result.t Or_error.t)]
  in
  let%bind () = confirm "000000" in
  let%bind () = confirm "123456" in
  (* Answered: the challenge authorizes nothing more. *)
  let%bind () = confirm "123456" in
  let%map info = Adapter.transfer t draft.id in
  print_s
    [%sexp (Or_error.map info ~f:(fun i -> i.status) : Transfer.Status.t Or_error.t)];
  [%expect
    {|
    (challenge (factors (Otp Passkey)) (attempts_left 5)
     (purpose (Transfer tr-1)))
    (Ok (Wrong_code (attempts_left 4)))
    (Ok Accepted)
    (Ok (Failed Cancelled))
    (Ok Settled)
    |}]
;;

let%expect_test "a payout above the balance fails the transfer, not the call" =
  let t =
    adapter
      [ ("GET", "/customers/external-accounts"), [ r "external-account-list.json" ]
      ; ("POST", "/quotes"), [ r ~status:400 "error-insufficient.json" ]
      ]
  in
  let events = Adapter.events t in
  let%bind started =
    Adapter.initiate_transfer t ~from:usd_account (sepa_draft (eur "1000.00"))
  in
  show_started started;
  let%map seen = return (drain events) in
  Queue.iter seen ~f:print_event;
  [%expect
    {|
    (done (status (Failed Insufficient_funds)) (fee "0.00 EUR"))
    ((e.id
      payee:ExternalAccount:00000000-0000-0000-0000-000000000001:UNSUPPORTED)
     (Payee_check (beneficiary ben-1) (result Not_possible)))
    ((e.id failed:tr-1)
     (Transfer (transfer tr-1) (provider_ref "")
      (update (Failed Insufficient_funds))))
    |}]
;;

(* {2 Conversions} *)

let%expect_test "a conversion between two accounts of a customer is a swap" =
  (* The recorded quote with its expiry moved to 2099: the adapter refuses to execute an
     expired quote by its own clock. *)
  let t =
    adapter
      [ ("POST", "/quotes"), [ r "quote-conversion.json" ]
      ; ( ("POST", "/quotes/Quote:00000000-0000-0000-0000-000000000001/execute")
        , [ r "quote-conversion-executed.json" ] )
      ; ( ("GET", "/transactions/Transaction:00000000-0000-0000-0000-000000000001")
        , [ r "transaction-conversion.json" ] )
      ]
  in
  let usdc_account =
    Refs.account
      ~customer_id:"Customer:00000000-0000-0000-0000-000000000001"
      ~account_id:"InternalAccount:00000000-0000-0000-0000-000000000002"
  in
  let events = Adapter.events t in
  let ten = Money.Amount.of_decimal_string Money.Currency.usd "10.00" |> ok_exn in
  let%bind q =
    Adapter.quote_swap t ~from:usd_account ~to_:usdc_account ~sell:ten >>| ok_exn
  in
  print_s
    [%message
      ""
        ~sell:(q.sell : Money.Amount.t)
        ~fee:(q.fee : Money.Amount.t)
        ~buy:(q.buy : Money.Amount.t)
        ~price:(Money.Rate.price_to_string (Money.Rate.price q.market) : string)];
  let%bind started = Adapter.execute_swap t q.id in
  print_s [%sexp (started : unit Sca_challenge.Or_challenge.t Or_error.t)];
  let%map seen = return (drain events) in
  Queue.iter seen ~f:(fun (e : Event.t) ->
    match e.kind with
    | Swap_executed { buy; _ } ->
      print_s [%message "Swap_executed" (buy : Money.Amount.t)]
    | kind -> print_s [%message (Event.Kind.name kind : string)]);
  [%expect
    {|
    ((sell "10.00 USD") (fee "0.00 USD") (buy "10.000000 USDC") (price 1))
    (Ok (Done ()))
    (Swap_executed (buy "10.000000 USDC"))
    |}]
;;

(* {2 Webhooks} *)

let public_key () =
  Lc.P256.public_key_of_pem (Fixture.read "webhooks/public.pem") |> ok_exn
;;

let delivery name =
  { Webhook.Request.headers =
      [ "X-Grid-Signature", Fixture.read ("webhooks/" ^ name ^ ".sig") ]
  ; body = Fixture.read ("webhooks/" ^ name ^ ".json")
  }
;;

let%expect_test "signed webhooks become events, once" =
  let store = Store.memory () in
  (* The transfer the failed payout belongs to, as initiate_transfer would have left it. *)
  let%bind () =
    store.set_transfer
      { id = Transfer.Id.of_string "tr-9"
      ; account = usd_account
      ; rail = Sepa_credit
      ; amount = eur "30.00"
      ; fee = Money.Amount.of_decimal_string Money.Currency.usd "0.60" |> ok_exn
      ; details = Intraledger
      ; quote_id = Some "Quote:00000000-0000-0000-0000-000000000009"
      ; provider_ref = None
      ; status = Submitted
      ; updated_at = Time_ns.epoch
      }
  in
  let t =
    adapter
      ~store
      ~webhook_public_key:(public_key ())
      [ ( ("GET", "/transactions/Transaction:00000000-0000-0000-0000-000000000009")
        , [ r "transaction-payout-failed.json" ] )
      ]
  in
  let ingest name =
    let%map result = Adapter.ingest_webhook t (delivery name) in
    match result with
    | Error e -> print_s [%message name (e : Error.t)]
    | Ok events ->
      print_s [%message name ~events:(List.length events : int)];
      List.iter events ~f:print_event
  in
  let%bind () = ingest "outgoing-failed" in
  let%bind () = ingest "incoming-completed" in
  let%bind () = ingest "kyc-approved" in
  let%bind () = ingest "test" in
  (* A redelivery publishes nothing new. *)
  let%bind () = ingest "incoming-completed" in
  let%bind () =
    let%map result =
      Adapter.ingest_webhook
        t
        { (delivery "test") with body = Fixture.read "webhooks/incoming-completed.json" }
    in
    print_s [%message "swapped body" ~_:(Result.is_ok result : bool)]
  in
  let%map info = Adapter.transfer t (Transfer.Id.of_string "tr-9") in
  print_s
    [%sexp (Or_error.map info ~f:(fun i -> i.status) : Transfer.Status.t Or_error.t)];
  [%expect
    {|
    (outgoing-failed (events 1))
    ((e.id tx:Transaction:00000000-0000-0000-0000-000000000009:FAILED)
     (Transfer (transfer tr-9)
      (provider_ref Transaction:00000000-0000-0000-0000-000000000009)
      (update (Rejected AC01))))
    (incoming-completed (events 2))
    ((e.id tx:Transaction:00000000-0000-0000-0000-000000000010:in)
     (Incoming_transfer
      (account
       Customer:00000000-0000-0000-0000-000000000001/InternalAccount:00000000-0000-0000-0000-000000000001)
      (transfer in:Transaction:00000000-0000-0000-0000-000000000010)
      (provider_ref Transaction:00000000-0000-0000-0000-000000000010)
      (rail Intraledger) (amount "2500.00 USD") (fee "0.00 USD")
      (from (External (name "bank deposit") (detail ""))) (reference payroll)
      (details Intraledger) (settled true)))
    ((e.id tx:Transaction:00000000-0000-0000-0000-000000000010:COMPLETED)
     (Transfer (transfer in:Transaction:00000000-0000-0000-0000-000000000010)
      (provider_ref Transaction:00000000-0000-0000-0000-000000000010)
      (update Settled)))
    (kyc-approved (events 4))
    ((e.id
      kyc:Customer:00000000-0000-0000-0000-000000000002:step:Identity_document:Verified)
     (Kyc (customer Customer:00000000-0000-0000-0000-000000000002)
      (update
       (Step (step Identity_document) (state (Verified "2026-10-14 06:23:00Z"))))))
    ((e.id
      kyc:Customer:00000000-0000-0000-0000-000000000002:step:Liveness:Verified)
     (Kyc (customer Customer:00000000-0000-0000-0000-000000000002)
      (update (Step (step Liveness) (state (Verified "2026-10-14 06:23:00Z"))))))
    ((e.id kyc:Customer:00000000-0000-0000-0000-000000000002:Created:Submit)
     (Kyc (customer Customer:00000000-0000-0000-0000-000000000002)
      (update (Status Submit))))
    ((e.id kyc:Customer:00000000-0000-0000-0000-000000000002:Verifying:Approve)
     (Kyc (customer Customer:00000000-0000-0000-0000-000000000002)
      (update (Status Approve))))
    (test (events 1))
    ((e.id ping:Webhook:00000000-0000-0000-0000-000000000004) Ping)
    (incoming-completed (events 0))
    ("swapped body" false)
    (Ok (Rejected AC01))
    |}]
;;

let%expect_test "without a webhook key every delivery is refused" =
  let t = adapter [] in
  let%map result = Adapter.ingest_webhook t (delivery "test") in
  print_s [%sexp (result : Event.t list Or_error.t)];
  [%expect
    {|
    (Error
     ("no Grid webhook public key configured"
      (variable LIGHTSPARK_GRID_WEBHOOK_PUBLIC_KEY)))
    |}]
;;

(* {2 What the adapter does not offer} *)

let%expect_test "cards, standing orders and sandbox outcomes" =
  let t = adapter [] in
  let card = Card_core.Ids.Card_id.of_string "card-1" in
  let%bind a = Adapter.card t card in
  print_s [%sexp (a : Card_info.t Or_error.t)];
  let%bind b =
    Adapter.simulate_transfer_outcome t (Transfer.Id.of_string "tr-1") Settled
  in
  print_s [%sexp (b : unit Or_error.t)];
  let%map c = Adapter.open_account t customer Money.Currency.eur in
  print_s [%sexp (Or_error.map c ~f:(fun _ -> ()) : unit Or_error.t)];
  [%expect
    {|
    (Error "cards are not supported by the Grid adapter")
    (Error
     "the Grid sandbox picks a payout's outcome from the last three digits of the payee's account number (002 fails, 003 is slow, 005 is returned, 010-013 are rejected); there is no call to change it afterwards")
    (Error
     ("this Grid platform holds no accounts in the currency" (code EUR)
      (supported (USD USDB USDC USDT))))
    |}]
;;
