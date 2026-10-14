(* A USD walk through the adapter on the Grid sandbox: what the conformance suite (EUR
   and IBAN based) cannot reach. Prints statuses and amounts, never ids or personal
   data. Runs only with LIGHTSPARK_LIVE_TESTS=1 and LIGHTSPARK_LIVE_WALK=1. *)

open! Core
open! Async
open Banking_provider
open Payments_core
module Adapter = Lightspark_provider.Adapter

let step name = Core.printf "-- %s\n%!" name
let ok_exn = Or_error.ok_exn

let await_event events ~what ~timeout f =
  let rec loop () =
    match%bind Pipe.read events with
    | `Eof -> return None
    | `Ok e ->
      (match f e with
       | Some x -> return (Some x)
       | None -> loop ())
  in
  match%map Clock_ns.with_timeout timeout (loop ()) with
  | `Result (Some x) -> Some x
  | `Result None | `Timeout ->
    Core.printf "   no %s within %s\n%!" what (Time_ns.Span.to_short_string timeout);
    None
;;

let walk () =
  let run_id =
    sprintf "lw%d" (Time_ns.to_int_ns_since_epoch (Time_ns.now ()) / 1_000_000_000)
  in
  let adapter =
    Adapter.of_env
      ~config:
        { Adapter.Config.default with
          email_for = Live_person.email_for
        ; poll_interval = Time_ns.Span.of_sec 2.
        }
      ()
    |> ok_exn
  in
  let events = Adapter.events adapter in
  step "customer";
  let%bind customer =
    Adapter.create_customer
      adapter
      ~customer_id:(Kyc_core.Customer_id.of_string (run_id ^ "-walk"))
      ~person:Live_person.person
    >>| ok_exn
  in
  let%bind kyc = Adapter.kyc_status adapter customer.id >>| ok_exn in
  Core.printf "   kyc %s\n" (Sexp.to_string [%sexp (kyc.status : Kyc_core.Status.t)]);
  step "USD account";
  let%bind usd = Adapter.open_account adapter customer.id Money.Currency.usd >>| ok_exn in
  Core.printf "   addresses %d\n" (List.length usd.addresses);
  let%bind bank = Adapter.us_bank_details adapter usd.id >>| ok_exn in
  Core.printf
    "   US bank details: %s\n"
    (match bank with
     | Some b -> sprintf "routing and account number, rails %s" (String.concat ~sep:"," b.rails)
     | None -> "none");
  step "deposit 100.00 USD";
  let hundred = Money.Amount.of_decimal_string Money.Currency.usd "100.00" |> ok_exn in
  let%bind deposit =
    Adapter.simulate_deposit adapter ~account:usd.id ~rail:Intraledger hundred >>| ok_exn
  in
  let%bind seen =
    await_event events ~what:"Incoming_transfer" ~timeout:(Time_ns.Span.of_sec 30.)
      (fun (e : Event.t) ->
         match e.kind with
         | Incoming_transfer { transfer; amount; settled; rail; _ }
           when Transfer.Id.equal transfer deposit -> Some (amount, settled, rail)
         | _ -> None)
  in
  Option.iter seen ~f:(fun (amount, settled, rail) ->
    Core.printf
      "   event Incoming_transfer %s settled=%b rail=%s\n"
      (Money.Amount.to_string amount)
      settled
      (Rail.to_string rail));
  let%bind b = Adapter.balance adapter usd.id >>| ok_exn in
  Core.printf
    "   balance available %s posted %s\n"
    (Money.Amount.to_string b.available)
    (Money.Amount.to_string b.posted);
  step "fee quote for EUR 30.00 by SEPA";
  let thirty = Money.Amount.of_decimal_string Money.Currency.eur "30.00" |> ok_exn in
  let%bind () =
    match%map Adapter.quote_fee adapter ~from:usd.id ~rail:Sepa_credit thirty with
    | Ok q ->
      Core.printf
        "   fee %s total %s\n"
        (Money.Amount.to_string q.fee)
        (Money.Amount.to_string q.total)
    | Error e -> Core.printf "   error %s\n" (Error.to_string_hum e)
  in
  step "cross-border payout EUR 30.00 to an IBAN";
  let sepa_draft ~id ~iban =
    let beneficiary =
      Beneficiary.create
        ~id:(Beneficiary.Id.of_string ("ben-" ^ id))
        ~owner:(Customer_ref.to_string customer.id)
        ~name:"Erika Payee"
        ~rail:Sepa_credit
        ~now:(Time_ns.now ())
        iban
      |> ok_exn
    in
    let party name =
      { Iso20022.Party.name; iban = Iban.of_string iban |> ok_exn; bic = None; address = None }
    in
    Transfer.draft
      ~id:(Transfer.Id.of_string id)
      ~rail:Sepa_credit
      ~account:(Ledger.Account_id.of_string "walk:app")
      ~beneficiary
      ~amount:thirty
      ~reference:"invoice 1"
      ~details:
        (Sepa
           (Sepa.Details.create
              ~payment_id:(Iso20022.Payment_id.create ~end_to_end_id:id () |> ok_exn)
              ~debtor:(party "Ada Sandbox")
              ~creditor:(party "Erika Payee")
              ()))
      ~now:(Time_ns.now ())
      ()
    |> ok_exn
  in
  let send ~from (draft : Transfer.t) =
    match%bind Adapter.initiate_transfer adapter ~from draft with
    | Error e ->
      Core.printf "   error %s\n" (String.prefix (Error.to_string_hum e) 400);
      return ()
    | Ok (Challenge c) ->
      Core.printf "   SCA challenge (%d attempts)\n" c.attempts_left;
      return ()
    | Ok (Done info) ->
      Core.printf
        "   started: %s fee %s\n"
        (Sexp.to_string [%sexp (info.status : Transfer.Status.t)])
        (Money.Amount.to_string info.fee);
      let%bind (_ : unit option) =
        await_event events ~what:"a final status" ~timeout:(Time_ns.Span.of_min 2.)
          (fun (e : Event.t) ->
             match e.kind with
             | Transfer { transfer; update; _ } when Transfer.Id.equal transfer draft.id ->
               Core.printf
                 "   event %s\n%!"
                 (Sexp.to_string [%sexp (update : Transfer_update.t)]);
               (match update with
                | Settled | Rejected _ | Failed _ | Returned _ -> Some ()
                | _ -> None)
             | _ -> None)
      in
      let%bind again = Adapter.initiate_transfer adapter ~from draft >>| ok_exn in
      Core.printf
        "   resend: %s\n"
        (match again with
         | Done i -> Sexp.to_string [%sexp (i.status : Transfer.Status.t)]
         | Challenge _ -> "challenge");
      let%map b = Adapter.balance adapter from >>| ok_exn in
      Core.printf
        "   balance available %s posted %s\n"
        (Money.Amount.to_string b.available)
        (Money.Amount.to_string b.posted)
  in
  let%bind () = send ~from:usd.id (sepa_draft ~id:(run_id ^ "-sepa") ~iban:"DE89370400440532013000") in
  (* Grid's sandbox fails a payout to an account number ending in 011 as ACCOUNT_INVALID. *)
  step "payout to an account the sandbox reports invalid";
  let%bind () = send ~from:usd.id (sepa_draft ~id:(run_id ^ "-bad") ~iban:"DE83370400440532013011") in
  step "conversion 10.00 USD to USDC";
  let%bind usdc = Adapter.open_account adapter customer.id Money.Currency.usdc >>| ok_exn in
  let ten = Money.Amount.of_decimal_string Money.Currency.usd "10.00" |> ok_exn in
  let%bind () =
    match%bind Adapter.quote_swap adapter ~from:usd.id ~to_:usdc.id ~sell:ten with
    | Error e ->
      Core.printf "   error %s\n" (String.prefix (Error.to_string_hum e) 400);
      return ()
    | Ok q ->
      Core.printf
        "   quote sell %s fee %s buy %s\n"
        (Money.Amount.to_string q.sell)
        (Money.Amount.to_string q.fee)
        (Money.Amount.to_string q.buy);
      let%bind started = Adapter.execute_swap adapter q.id >>| ok_exn in
      Core.printf
        "   execute: %s\n"
        (match started with
         | Done () -> "done"
         | Challenge _ -> "challenge");
      let%map (_ : unit option) =
        await_event events ~what:"swap result" ~timeout:(Time_ns.Span.of_min 1.)
          (fun (e : Event.t) ->
             match e.kind with
             | Swap_executed { swap; buy; _ } when Swap.Id.equal swap q.id ->
               Core.printf "   event Swap_executed buy %s\n" (Money.Amount.to_string buy);
               Some ()
             | Swap_failed { swap; reason } when Swap.Id.equal swap q.id ->
               Core.printf "   event Swap_failed %s\n" reason;
               Some ()
             | _ -> None)
      in
      ()
  in
  let%bind b = Adapter.balance adapter usd.id >>| ok_exn in
  Core.printf
    "   USD balance available %s posted %s\n"
    (Money.Amount.to_string b.available)
    (Money.Amount.to_string b.posted);
  step "on-chain payout 1.000000 USDC on Ethereum";
  let%bind () =
    let address = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed" in
    let id = run_id ^ "-chain" in
    let person name account =
      { Travel_rule.Person.name
      ; account
      ; identification = Some (Customer_number (run_id ^ "-walk"))
      ; lei = None
      }
    in
    let draft =
      Transfer.draft
        ~id:(Transfer.Id.of_string id)
        ~rail:(Onchain Ethereum)
        ~account:(Ledger.Account_id.of_string "walk:app")
        ~beneficiary:
          (Beneficiary.create
             ~id:(Beneficiary.Id.of_string ("ben-" ^ id))
             ~owner:(Customer_ref.to_string customer.id)
             ~name:"Erika Payee"
             ~rail:(Onchain Ethereum)
             ~now:(Time_ns.now ())
             address
           |> ok_exn)
        ~amount:(Money.Amount.of_decimal_string Money.Currency.usdc "1.000000" |> ok_exn)
        ~details:
          (Onchain
             { travel_rule =
                 Some
                   { originator = person "Ada Sandbox" (Account_ref.to_string usdc.id)
                   ; beneficiary = person "Erika Payee" address
                   ; counterparty_wallet = Self_hosted { ownership_verified = true }
                   }
             ; tx_hash = None
             ; block_hash = None
             ; confirmations = 0
             ; finalized = false
             })
        ~now:(Time_ns.now ())
        ()
      |> ok_exn
    in
    send ~from:usdc.id draft
  in
  step "statement";
  let%bind () =
    let until = Time_ns.now () in
    match%map
      Adapter.statement adapter usd.id ~from:(Time_ns.sub until Time_ns.Span.hour) ~until
    with
    | Error e -> Core.printf "   error %s\n" (String.prefix (Error.to_string_hum e) 400)
    | Ok s ->
      Core.printf
        "   opening %s, %d lines, closing %s, check %s\n"
        (Money.Amount.to_string s.opening)
        (List.length s.lines)
        (Money.Amount.to_string s.closing)
        (match Statement.check s with
         | Ok () -> "ok"
         | Error e -> Error.to_string_hum e);
      List.iter s.lines ~f:(fun l ->
        Core.printf
          "   %s %s -> %s\n"
          (Time_ns.to_string_utc l.at)
          (Money.Amount.to_string l.amount)
          (Money.Amount.to_string l.balance))
  in
  step "ping";
  let%map () =
    match%map Adapter.ping adapter with
    | Ok () -> Core.printf "   ok\n"
    | Error e -> Core.printf "   error %s\n" (String.prefix (Error.to_string_hum e) 300)
  in
  Pipe.close_read events;
  List.iter (Adapter.background_errors adapter) ~f:(fun e ->
    Core.printf "background: %s\n" (String.prefix (Error.to_string_hum e) 300))
;;

let () =
  let flag v = Option.equal String.equal (Sys.getenv v) (Some "1") in
  if not (flag "LIGHTSPARK_LIVE_TESTS" && flag "LIGHTSPARK_LIVE_WALK")
  then
    Core.print_endline
      "lightspark-provider walk skipped (set LIGHTSPARK_LIVE_TESTS=1 and \
       LIGHTSPARK_LIVE_WALK=1)"
  else Command_unix.run (Command.async ~summary:"USD walk on the Grid sandbox" (Command.Param.return walk))
;;
