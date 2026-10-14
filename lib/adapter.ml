open! Core
open Async
open Banking_provider
open Payments_core
module Lc = Lightspark_client
module Ids = Card_core.Ids
module Transfer_record = Store.Transfer_record
module Challenge_record = Store.Challenge_record
module Swap_record = Store.Swap_record

module Config = struct
  type t =
    { poll_interval : Time_ns.Span.t
    ; provisioning_timeout : Time_ns.Span.t
    ; email_for : Kyc_core.Customer_id.t -> email:string -> string
    ; payee_country : string
    ; end_user_ip : string option
    ; webhook_public_key : Lc.P256.public_key option
    ; transactions_pages : int
    }

  (* [local+tag@domain]: Grid wants a deliverable address per customer, and test runs
     reuse one synthetic person. Tags keep only characters every mail system accepts. *)
  let tagged_email customer_id ~email =
    let tag =
      String.filter_map (Kyc_core.Customer_id.to_string customer_id) ~f:(fun c ->
        if Char.is_alphanum c || Char.equal c '-' then Some (Char.lowercase c) else None)
    in
    match String.lsplit2 email ~on:'@' with
    | Some (local, domain) ->
      let local = List.hd_exn (String.split local ~on:'+') in
      sprintf "%s+%s@%s" local tag domain
    | None -> email
  ;;

  let default =
    { poll_interval = Time_ns.Span.of_sec 3.
    ; provisioning_timeout = Time_ns.Span.of_min 2.
    ; email_for = tagged_email
    ; payee_country = "US"
    ; end_user_ip = None
    ; webhook_public_key = None
    ; transactions_pages = 3
    }
  ;;
end

type t =
  { config : Config.t
  ; api : Grid_api.t
  ; store : Store.t
  ; subscribers : Event.t Pipe.Writer.t Bag.t
  ; published : Event_id.t Hash_set.t
  ; kyc_seen : (string, Customer.Kyc_status.t) Hashtbl.t (** by Grid customer id *)
  ; attempts : (Sca.Id.t, int) Hashtbl.t
  ; mutable currencies : string list option (** the platform's, cached *)
  ; mutable captures : Event.t Queue.t list
  ; mutable polling : bool
  ; mutable errors : Error.t list
  ; mutable deposits : int
  ; mutable swaps : int
  }

let api t = t.api
let background_errors t = List.rev t.errors
let name _ = "lightspark"
let now () = Time_ns.now ()
let note_error t e = t.errors <- e :: t.errors

let create ?(config = Config.default) ?(store = Store.memory ()) api =
  { config
  ; api
  ; store
  ; subscribers = Bag.create ()
  ; published = Hash_set.create (module Event_id)
  ; kyc_seen = Hashtbl.create (module String)
  ; attempts = Hashtbl.create (module Sca.Id)
  ; currencies = None
  ; captures = []
  ; polling = false
  ; errors = []
  ; deposits = 0
  ; swaps = 0
  }
;;

let webhook_key_var = "LIGHTSPARK_GRID_WEBHOOK_PUBLIC_KEY"

let of_env ?(config = Config.default) ?store ?live () =
  let open Or_error.Let_syntax in
  let%bind lc = Lc.Config.of_env ?live () in
  let%map webhook_public_key =
    match config.webhook_public_key, Sys.getenv webhook_key_var with
    | Some k, _ -> Ok (Some k)
    | None, (None | Some "") -> Ok None
    | None, Some pem ->
      (* Environment files cannot hold newlines easily; accept [\n] escapes. *)
      let pem = String.substr_replace_all pem ~pattern:"\\n" ~with_:"\n" in
      Or_error.map (Lc.P256.public_key_of_pem pem) ~f:Option.some
  in
  create ~config:{ config with webhook_public_key } ?store (Grid_api.create lc)
;;

(* Grid errors become Or_error with the request id and Grid's code kept. *)
let lift d = Deferred.map d ~f:(Result.map_error ~f:Lc.Api_error.to_error)

let grid_code (e : Lc.Api_error.t) =
  match e with
  | Http { code; _ } -> code
  | _ -> None
;;

(* {2 Events} *)

let publish t (e : Event.t) =
  if not (Hash_set.mem t.published e.id)
  then (
    Hash_set.add t.published e.id;
    List.iter t.captures ~f:(fun q -> Queue.enqueue q e);
    Bag.iter t.subscribers ~f:(fun w ->
      if not (Pipe.is_closed w) then Pipe.write_without_pushback w e))
;;

let event ~id ~at kind = { Event.id = Event_id.of_string id; at; kind }

(* {2 KYC} *)

let observe_customer t (c : Grid_api.Customer.t) =
  let customer = Refs.customer c.id in
  let at = now () in
  let previous =
    Hashtbl.find t.kyc_seen c.id
    |> Option.value ~default:(Customer.Kyc_status.initial customer)
  in
  let current = Kyc_map.kyc_status customer ~previous c ~at in
  Hashtbl.set t.kyc_seen ~key:c.id ~data:current;
  List.iter (Kyc_map.events ~previous ~current ~at) ~f:(publish t);
  current
;;

let track_customer t id =
  if not (Hashtbl.mem t.kyc_seen id)
  then Hashtbl.set t.kyc_seen ~key:id ~data:(Customer.Kyc_status.initial (Refs.customer id))
;;

let fetch_kyc t ~customer_id =
  let%map.Deferred.Or_error c = lift (Grid_api.customer t.api ~id:customer_id) in
  observe_customer t c
;;

(* {2 Transfers} *)

let status_rank (s : Transfer.Status.t) =
  match s with
  | Draft -> 0
  | Awaiting_sca -> 1
  | Submitted -> 2
  | Pending -> 3
  | Timed_out -> 4
  | Settled -> 5
  | Recall_requested _ | Recall_refused _ -> 6
  | Rejected _ | Failed _ | Returned _ | Recalled | Cancelled | Reorged -> 7
;;

let status_of_update (u : Transfer_update.t) : Transfer.Status.t option =
  match u with
  | Submitted -> Some Submitted
  | Pending -> Some Pending
  | Settled | Lightning_paid _ -> Some Settled
  | Rejected r -> Some (Rejected r)
  | Failed f -> Some (Failed f)
  | Timed_out -> Some Timed_out
  | Returned r -> Some (Returned r)
  | Cancelled -> Some Cancelled
  | Recall_requested r -> Some (Recall_requested r)
  | Recall_answer { accepted = true; _ } -> Some Recalled
  | Recall_answer { accepted = false; reason } -> Some (Recall_refused reason)
  | Reorged _ -> Some Reorged
  | Status_report _ | Confirmations _ -> None
;;

(* Moves the stored transfer forward unless it is already at or past the update; a
   returned payment (rank 7) still replaces a settled one (rank 5). *)
let advance t (r : Transfer_record.t) (u : Transfer_update.t) =
  match status_of_update u with
  | Some s when status_rank s > status_rank r.status ->
    let r = { r with status = s; updated_at = now () } in
    let%map () = t.store.set_transfer r in
    r
  | _ -> return r
;;

let info_of (r : Transfer_record.t) =
  { Transfer_info.transfer = r.id
  ; provider_ref = Option.value r.provider_ref ~default:(Option.value r.quote_id ~default:"")
  ; status = r.status
  ; fee = r.fee
  ; details = r.details
  ; updated_at = r.updated_at
  }
;;

let tx_time (tx : Grid_api.Transaction.t) =
  Grid_time.parse_or ~default:(now ()) (Option.first_some tx.updated_at tx.created_at)
;;

let observe_outgoing t (r : Transfer_record.t) (tx : Grid_api.Transaction.t) =
  let r =
    if Option.is_none r.provider_ref
    then { r with provider_ref = Some tx.id; details = Tx_map.details tx }
    else r
  in
  match Tx_map.outgoing_update tx with
  | None -> t.store.set_transfer r
  | Some u ->
    let%map (_ : Transfer_record.t) = advance t r u in
    publish
      t
      { id = Tx_map.event_id tx
      ; at = tx_time tx
      ; kind = Transfer { transfer = r.id; provider_ref = tx.id; update = u }
      }
;;

let observe_swap t (s : Swap_record.t) (tx : Grid_api.Transaction.t) =
  let swap = s.id in
  let id suffix = sprintf "swap:%s:%s" (Swap.Id.to_string swap) suffix in
  let at = tx_time tx in
  match tx.status with
  | "COMPLETED" ->
    publish
      t
      (event
         ~id:(id "executed")
         ~at
         (Swap_executed { swap; sell = s.sell; fee = s.fee; buy = s.buy }));
    if s.executed then return () else t.store.set_swap { s with executed = true }
  | "FAILED" | "REJECTED" | "EXPIRED" | "REFUNDED" ->
    publish
      t
      (event
         ~id:(id "failed")
         ~at
         (Swap_failed
            { swap
            ; reason = Option.value tx.failure_reason ~default:(String.lowercase tx.status)
            }));
    return ()
  | _ -> return ()
;;

let observe_tx t (tx : Grid_api.Transaction.t) =
  let by_quote f = Option.value_map tx.quote_id ~default:(return None) ~f in
  match%bind by_quote t.store.find_swap_by_quote with
  | Some s -> observe_swap t s tx
  | None ->
    let%bind outgoing =
      match%bind t.store.find_transfer_by_ref tx.id with
      | Some r -> return (Some r)
      | None -> by_quote t.store.find_transfer_by_quote
    in
    (match outgoing, tx.type_ with
     | Some r, _ -> observe_outgoing t r tx
     | None, "INCOMING" ->
       (match tx.customer_id, tx.destination_account_id with
        | Some customer_id, Some account_id ->
          let account = Refs.account ~customer_id ~account_id in
          (match Tx_map.incoming ~account tx with
           | Ok events -> List.iter events ~f:(publish t)
           | Error e -> note_error t (Error.tag e ~tag:tx.id));
          return ()
        | _ -> return ())
     | None, _ -> return ())
;;

let scan_customer t ~customer_id =
  match%bind
    lift
      (Grid_api.transactions t.api ~customer_id ~max_pages:t.config.transactions_pages)
  with
  | Error _ as e -> return e
  | Ok txs ->
    (* Oldest first, so a transfer moves forward through its states. *)
    let%map () = Deferred.List.iter ~how:`Sequential (List.rev txs) ~f:(observe_tx t) in
    Ok ()
;;

(* {2 Polling} *)

let poll_once t =
  Deferred.List.iter ~how:`Sequential (Hashtbl.keys t.kyc_seen) ~f:(fun customer_id ->
    let%bind () =
      match%map fetch_kyc t ~customer_id with
      | Ok (_ : Customer.Kyc_status.t) -> ()
      | Error e -> note_error t e
    in
    match%map scan_customer t ~customer_id with
    | Ok () -> ()
    | Error e -> note_error t e)
;;

let rec poll_loop t =
  if Bag.is_empty t.subscribers
  then (
    t.polling <- false;
    return ())
  else (
    let%bind () = poll_once t in
    let%bind () = Clock_ns.after t.config.poll_interval in
    poll_loop t)
;;

let events t =
  let r, w = Pipe.create () in
  let elt = Bag.add t.subscribers w in
  don't_wait_for
    (let%map () = Pipe.closed w in
     Bag.remove t.subscribers elt);
  if not t.polling
  then (
    t.polling <- true;
    don't_wait_for (poll_loop t));
  r
;;

let poll_until ~timeout ~every f =
  let deadline = Time_ns.add (now ()) timeout in
  let rec loop () =
    match%bind f () with
    | Error _ as e -> return e
    | Ok (Some x) -> return (Ok x)
    | Ok None ->
      if Time_ns.( > ) (now ()) deadline
      then return (Or_error.error_string "timed out")
      else (
        let%bind () = Clock_ns.after every in
        loop ())
  in
  loop ()
;;

(* {2 Customers} *)

let new_customer t ~customer_id (person : Kyc_core.Person.t) =
  let reveal = Kyc_core.Pii.reveal in
  let address = reveal person.residential_address in
  { Grid_api.New_customer.platform_customer_id = Kyc_core.Customer_id.to_string customer_id
  ; full_name = reveal person.given_name ^ " " ^ reveal person.family_name
  ; birth_date = reveal person.date_of_birth
  ; nationality = Kyc_core.Country.to_string (reveal person.nationality)
  ; email = t.config.email_for customer_id ~email:(reveal person.email)
  ; address_line1 = address.line1
  ; address_line2 = address.line2
  ; city = address.city
  ; region = address.region
  ; postal_code = Option.value address.postal_code ~default:""
  ; country = Kyc_core.Country.to_string address.country
  }
;;

let customer_of ~customer_id (c : Grid_api.Customer.t) =
  { Customer.id = Refs.customer c.id
  ; customer_id
  ; created_at = Grid_time.parse_or ~default:(now ()) (Some c.created_at)
  }
;;

let create_customer t ~customer_id ~person =
  let platform_customer_id = Kyc_core.Customer_id.to_string customer_id in
  let finish (c : Grid_api.Customer.t) =
    track_customer t c.id;
    ignore (observe_customer t c : Customer.Kyc_status.t);
    Ok (customer_of ~customer_id c)
  in
  match%bind lift (Grid_api.find_customer t.api ~platform_customer_id) with
  | Error _ as e -> return e
  | Ok (Some c) -> return (finish c)
  | Ok None ->
    (match%bind
       Grid_api.create_customer
         t.api
         (new_customer t ~customer_id person)
         ~idempotency_key:("customer-" ^ platform_customer_id)
     with
     | Ok c -> return (finish c)
     | Error e when Option.equal String.equal (grid_code e) (Some "CONFLICT") ->
       (* Created by a lost earlier response under another key: read it back. *)
       (match%map lift (Grid_api.find_customer t.api ~platform_customer_id) with
        | Ok (Some c) -> finish c
        | Ok None -> Error (Lc.Api_error.to_error e)
        | Error _ as e -> e)
     | Error e -> return (Error (Lc.Api_error.to_error e)))
;;

let update_customer t customer ~person =
  let id = Refs.customer_id customer in
  match%bind lift (Grid_api.customer t.api ~id) with
  | Error _ as e -> return e
  | Ok c ->
    let customer_id =
      Kyc_core.Customer_id.of_string (Option.value c.platform_customer_id ~default:id)
    in
    lift (Grid_api.update_customer t.api ~id (new_customer t ~customer_id person))
;;

let code_validity = Time_ns.Span.of_min 10.

let start_verification t customer (step : Kyc_core.Verification.Step.t) =
  let id = Refs.customer_id customer in
  track_customer t id;
  let contact which =
    let%map.Deferred.Or_error () =
      lift (Grid_api.start_contact_verification t.api ~id which)
    in
    Customer.Verification_session.Code_sent
      { step; expires_at = Time_ns.add (now ()) code_validity }
  in
  match step with
  | Email -> contact `Email
  | Mobile -> contact `Phone
  | Identity_document | Liveness ->
    let%map.Deferred.Or_error link = lift (Grid_api.kyc_link t.api ~id) in
    Customer.Verification_session.Hosted
      { step
      ; token = Sensitive.of_string (Option.value link.token ~default:link.url)
      ; expires_at =
          Grid_time.parse_or
            ~default:(Time_ns.add (now ()) Time_ns.Span.hour)
            (Some link.expires_at)
      }
  | Address_proof | Source_of_funds ->
    return
      (Or_error.error_s
         [%message
           "Grid verifies identity in one hosted flow and has no separate step"
             (step : Kyc_core.Verification.Step.t)])
;;

let complete_verification t customer (step : Kyc_core.Verification.Step.t) ~code =
  let id = Refs.customer_id customer in
  let state_of (status : Customer.Kyc_status.t) =
    List.Assoc.find status.steps step ~equal:Kyc_core.Verification.Step.equal
    |> Option.value ~default:Kyc_core.Verification.State.Pending
  in
  let contact which =
    match%bind
      Grid_api.confirm_contact_verification t.api ~id which ~code:(Sensitive.reveal code)
    with
    | Ok (_ : Grid_api.Customer.t) ->
      let%map.Deferred.Or_error status = fetch_kyc t ~customer_id:id in
      state_of status
    | Error (Http { status = 400 | 401 | 403 | 422; _ }) ->
      (* Grid refuses a wrong code; the step stays open and may be started again. *)
      return (Ok (Kyc_core.Verification.State.Failed "wrong code"))
    | Error e -> return (Error (Lc.Api_error.to_error e))
  in
  match step with
  | Email -> contact `Email
  | Mobile -> contact `Phone
  | _ ->
    let%map.Deferred.Or_error status = fetch_kyc t ~customer_id:id in
    state_of status
;;

let kyc_status t customer =
  let id = Refs.customer_id customer in
  track_customer t id;
  fetch_kyc t ~customer_id:id
;;

(* {2 Accounts} *)

let platform_currencies t =
  match t.currencies with
  | Some cs -> return (Ok cs)
  | None ->
    let%map.Deferred.Or_error config = lift (Lc.Grid.platform_config (Grid_api.grid t.api)) in
    let cs =
      List.map config.supported_currencies ~f:(fun (c : Lc.Grid_types.Supported_currency.t) ->
        c.currency_code)
    in
    t.currencies <- Some cs;
    cs
;;

let grid_accounts t ~customer_id = lift (Grid_api.customer_accounts t.api ~customer_id)

let find_grid_account t account =
  match Refs.account_parts account with
  | Error _ as e -> return e
  | Ok (customer_id, account_id) ->
    let%bind.Deferred.Or_error accounts = grid_accounts t ~customer_id in
    return
      (match
         List.find accounts ~f:(fun (a : Grid_api.Internal_account.t) ->
           String.equal a.id account_id)
       with
       | Some a -> Ok (customer_id, a)
       | None ->
         Or_error.error_s [%message "no such Grid account" (account : Account_ref.t)])
;;

let account_opened t (a : Account.t) =
  publish
    t
    (event ~id:("account:" ^ Account_ref.to_string a.id ^ ":opened") ~at:a.opened_at
       (Account_opened a))
;;

(* The account Grid holds for a currency: the custodial one when a currency also has an
   embedded (self-custody) wallet. *)
let pick_account ~code (accounts : Grid_api.Internal_account.t list) =
  let matching =
    List.filter accounts ~f:(fun a -> String.equal a.balance.code code)
  in
  match
    List.find matching ~f:(fun a -> not (String.equal a.type_ "EMBEDDED_WALLET"))
  with
  | Some a -> Some a
  | None -> List.hd matching
;;

let open_account t customer currency =
  let customer_id = Refs.customer_id customer in
  let code = Units.code currency in
  track_customer t customer_id;
  match%bind platform_currencies t with
  | Error _ as e -> return e
  | Ok supported when not (List.mem supported code ~equal:String.equal) ->
    return
      (Or_error.error_s
         [%message
           "this Grid platform holds no accounts in the currency"
             (code : string)
             (supported : string list)])
  | Ok _ ->
    (* Grid opens one account per supported currency itself, a moment after the
       customer; opening is waiting for it. *)
    (match%map
       poll_until
         ~timeout:t.config.provisioning_timeout
         ~every:t.config.poll_interval
         (fun () ->
            let%map.Deferred.Or_error accounts = grid_accounts t ~customer_id in
            pick_account ~code accounts)
     with
     | Error e -> Error (Error.tag e ~tag:("waiting for the " ^ code ^ " account"))
     | Ok a ->
       (match Account_map.account ~customer_id a with
        | Error _ as e -> e
        | Ok account ->
          account_opened t account;
          Ok account))
;;

let accounts t customer =
  let customer_id = Refs.customer_id customer in
  let%map.Deferred.Or_error accounts = grid_accounts t ~customer_id in
  (* Currencies [money] cannot represent are left out rather than failing the list. *)
  List.filter_map accounts ~f:(fun a -> Result.ok (Account_map.account ~customer_id a))
;;

let balance t account =
  match%map find_grid_account t account with
  | Error _ as e -> e
  | Ok (_, a) -> Account_map.balance account a ~at:(now ())
;;

let enrich_account t account =
  match%map find_grid_account t account with
  | Error _ as e -> e
  | Ok (customer_id, a) -> Account_map.account ~customer_id a
;;

let us_bank_details t account =
  let%map.Deferred.Or_error _, a = find_grid_account t account in
  Account_map.us_bank_details a
;;

let statement t account ~from ~until =
  match%bind find_grid_account t account with
  | Error _ as e -> return e
  | Ok (_, a) ->
    let stop = Time_ns.min until (now ()) in
    let changes ~start ~stop =
      if Time_ns.( >= ) start stop
      then return (Ok [])
      else lift (Grid_api.balance_changes t.api ~account_id:a.id ~start ~stop)
    in
    let%bind.Deferred.Or_error within = changes ~start:from ~stop in
    let%bind.Deferred.Or_error after = changes ~start:stop ~stop:(now ()) in
    return
      (let open Or_error.Let_syntax in
       let%bind balance = Account_map.balance account a ~at:(now ()) in
       let currency = Money.Amount.currency balance.posted in
       let amounts l =
         List.map l ~f:(fun (c : Grid_api.Balance_change.t) ->
           Grid_api.Amount.to_money c.amount)
         |> Or_error.all
       in
       let%bind within_amounts = amounts within in
       let%bind after_amounts = amounts after in
       let%bind after_sum = Money.Amount.sum currency after_amounts in
       let%bind within_sum = Money.Amount.sum currency within_amounts in
       (* Balance changes add up to the posted balance: walk back from today. *)
       let%bind closing = Money.Amount.sub balance.posted after_sum in
       let%bind opening = Money.Amount.sub closing within_sum in
       let%bind lines, (_ : Money.Amount.t) =
         List.zip_exn within within_amounts
         |> List.sort ~compare:(fun ((a : Grid_api.Balance_change.t), _) (b, _) ->
           String.compare a.effective_at b.effective_at)
         |> List.fold_result ~init:([], opening) ~f:(fun (acc, running) (c, amount) ->
           let%map balance = Money.Amount.add running amount in
           ( { Statement.Line.at = Grid_time.parse_or ~default:from (Some c.effective_at)
             ; amount
             ; code = (if Money.Amount.is_negative amount then "DEBIT" else "CREDIT")
             ; reference = Option.value c.transaction_id ~default:c.id
             ; balance
             }
             :: acc
           , balance ))
       in
       Ok
         { Statement.account
         ; currency
         ; from
         ; until
         ; opening
         ; lines = List.rev lines
         ; closing
         })
;;

(* {2 SCA} *)

let factors_of (c : Grid_api.Sca_challenge.t) : Sca.Kind.t list =
  let kind = function
    | "PASSKEY" -> Sca.Kind.Passkey
    | "TOTP" -> Totp
    | _ -> Otp
  in
  List.dedup_and_sort
    ~compare:Sca.Kind.compare
    (List.map (c.factor :: c.available_factors) ~f:kind)
;;

(* Grid does not say how many attempts a challenge allows; five, like most issuers. *)
let max_attempts = 5

let new_challenge t ~purpose ~quote_id (c : Grid_api.Sca_challenge.t) =
  let challenge =
    { Sca_challenge.id = Sca.Id.of_string ("grid:" ^ quote_id ^ ":" ^ c.id)
    ; purpose
    ; factors = factors_of c
    ; expires_at =
        Grid_time.parse_or
          ~default:(Time_ns.add (now ()) (Time_ns.Span.of_min 5.))
          (Some c.expires_at)
    ; attempts_left = max_attempts
    }
  in
  let%map () = t.store.set_challenge { challenge; quote_id; settled = false } in
  challenge
;;

(* {2 Transfers} *)

let quote_fee t ~from ~rail amount =
  match%bind find_grid_account t from with
  | Error _ as e -> return e
  | Ok (_, a) ->
    let source = a.balance.code in
    let destination = Units.code (Money.Amount.currency amount) in
    let zero_fee () =
      let open Or_error.Let_syntax in
      let%bind fee = Grid_api.Amount.to_money { a.balance with minor = 0 } in
      let%map total = Money.Amount.add amount fee in
      { Transfer_info.Fee_quote.rail; amount; fee; total }
    in
    if String.equal source destination
    then
      (* Grid publishes no fee for a payout in the account's own currency; the quote at
         initiation carries the real one. *)
      return (zero_fee ())
    else (
      let rail_name =
        match (rail : Rail.t) with
        | Sepa_credit -> Some "SEPA"
        | Sepa_instant -> Some "SEPA_INSTANT"
        | _ -> None
      in
      let pick (rates : Grid_api.Rate.t list) =
        match
          List.find rates ~f:(fun r -> Option.equal String.equal r.rail rail_name)
        with
        | Some r -> Some r
        | None -> List.hd rates
      in
      let%bind.Deferred.Or_error receive = return (Units.to_grid amount) in
      let%bind.Deferred.Or_error first = lift (Grid_api.rates t.api ~source ~destination) in
      match pick first with
      | None ->
        return
          (Or_error.error_s
             [%message "Grid quotes no rate for the pair" source destination])
      | Some r ->
        let sending =
          Float.iround_up_exn (Float.of_int receive *. r.exchange_rate)
        in
        (* Fees depend on the size, so ask again for this amount. *)
        let%bind.Deferred.Or_error sized =
          lift (Grid_api.rates t.api ~source ~destination ~sending_amount:sending)
        in
        let r = Option.value (pick sized) ~default:r in
        let fee_minor = Option.value r.fee_total ~default:0 in
        return
          (let open Or_error.Let_syntax in
           let%bind fee =
             Grid_api.Amount.to_money { a.balance with minor = fee_minor }
           in
           let%map total =
             Grid_api.Amount.to_money { a.balance with minor = sending + fee_minor }
           in
           { Transfer_info.Fee_quote.rail; amount; fee; total }))
;;

let insufficient e =
  match grid_code e with
  | Some code -> String.is_substring code ~substring:"INSUFFICIENT"
  | None -> false
;;

(* A payment Grid refused for lack of funds: [Failed Insufficient_funds], published like
   a status report so the application's transfer finishes. *)
let fail_transfer t (r : Transfer_record.t) (reason : Transfer.Failure_reason.t) =
  let r = { r with status = Failed reason; updated_at = now () } in
  let%map () = t.store.set_transfer r in
  publish
    t
    (event
       ~id:("failed:" ^ Transfer.Id.to_string r.id)
       ~at:r.updated_at
       (Transfer
          { transfer = r.id
          ; provider_ref = Option.value r.quote_id ~default:""
          ; update = Failed reason
          }));
  r
;;

let refresh_transfer t (r : Transfer_record.t) =
  match r.provider_ref with
  | None -> return (Ok r)
  | Some id ->
    (match%bind lift (Grid_api.transaction t.api ~id) with
     | Error _ as e -> return e
     | Ok tx ->
       let%bind () = observe_outgoing t r tx in
       (match%map t.store.find_transfer r.id with
        | Some r -> Ok r
        | None -> Ok r))
;;

(* Executes an authorized (or SCA-free) quote and records the transaction. *)
let execute_transfer t (r : Transfer_record.t) ~quote_id =
  match%bind
    Grid_api.execute_quote
      t.api
      ~id:quote_id
      ~idempotency_key:(Transfer.Id.to_string r.id ^ ":execute")
  with
  | Error e when insufficient e ->
    let%map r = fail_transfer t r Insufficient_funds in
    Ok r
  | Error e -> return (Error (Lc.Api_error.to_error e))
  | Ok q ->
    let r =
      { r with
        provider_ref = Option.first_some q.transaction_id r.provider_ref
      ; status = (if status_rank r.status < 2 then Submitted else r.status)
      ; updated_at = now ()
      }
    in
    let%bind () = t.store.set_transfer r in
    publish
      t
      (event
         ~id:("submitted:" ^ Transfer.Id.to_string r.id)
         ~at:r.updated_at
         (Transfer
            { transfer = r.id
            ; provider_ref = Option.value r.provider_ref ~default:quote_id
            ; update = Submitted
            }));
    refresh_transfer t r
;;

let external_account t ~customer_id ~currency ~account_info ~platform_account_id =
  match%bind lift (Grid_api.external_accounts t.api ~customer_id) with
  | Error _ as e -> return e
  | Ok existing ->
    (match
       List.find existing ~f:(fun (e : Grid_api.External_account.t) ->
         Option.equal String.equal e.platform_account_id (Some platform_account_id)
         && String.equal e.currency currency)
     with
     | Some e -> return (Ok e)
     | None ->
       lift
         (Grid_api.create_external_account
            t.api
            ~customer_id
            ~currency
            ~platform_account_id
            ~account_info
            ~idempotency_key:(customer_id ^ ":" ^ platform_account_id ^ ":" ^ currency)))
;;

let payee_check_event t (beneficiary : Beneficiary.t) (e : Grid_api.External_account.t) =
  let result : Beneficiary.Payee_check.t option =
    match e.beneficiary_verification with
    | Some "MATCHED" -> Some Match
    | Some "PARTIAL_MATCH" -> Some (Close_match { suggested_name = beneficiary.name })
    | Some "NOT_MATCHED" -> Some No_match
    | Some ("UNSUPPORTED" | "CHECKED_BY_RECEIVING_FI") -> Some Not_possible
    | _ -> None
  in
  Option.iter result ~f:(fun result ->
    publish
      t
      (event
         ~id:(sprintf "payee:%s:%s" e.id (Option.value e.beneficiary_verification ~default:""))
         ~at:(now ())
         (Payee_check { beneficiary = beneficiary.id; result })))
;;

let start_transfer t ~customer_id ~account_id (draft : Transfer.t) =
  let open Deferred.Or_error.Let_syntax in
  let%bind payee =
    Deferred.return (Payee.of_transfer draft ~payee_country:t.config.payee_country)
  in
  let%bind destination_id, payment_rail =
    match payee with
    | Internal { account_id } -> return (account_id, None)
    | External { currency; account_info; payment_rail; platform_account_id } ->
      let%map e =
        external_account t ~customer_id ~currency ~account_info ~platform_account_id
      in
      (match draft.counterparty with
       | Beneficiary b -> payee_check_event t b e
       | External _ -> ());
      e.id, payment_rail
  in
  let%bind amount = Deferred.return (Units.to_grid draft.amount) in
  let%bind q =
    lift
      (Grid_api.create_quote
         t.api
         ~source_account_id:account_id
         ~destination:(Account { account_id = destination_id; payment_rail })
         ~locked:`Receiving
         ~amount
         ~description:(String.prefix draft.reference 1024)
         ~idempotency_key:(Transfer.Id.to_string draft.id))
  in
  let%bind fee =
    Deferred.return
      (Units.amount ~code:q.sending_code ~decimals:q.sending_decimals q.fees_included)
  in
  return (q, fee)
;;

let initiate_transfer t ~from (draft : Transfer.t) =
  match%bind t.store.find_transfer draft.id with
  | Some r ->
    (* A resend: report what the first call started. A transfer still waiting for SCA
       gets its open challenge again. *)
    (match r.status, r.quote_id with
     | Awaiting_sca, Some quote_id ->
       (match%bind lift (Grid_api.quote t.api ~id:quote_id) with
        | Error _ as e -> return e
        | Ok { status = "PENDING_AUTHORIZATION"; sca_challenge = Some c; _ } ->
          let%map ch = new_challenge t ~purpose:(Transfer r.id) ~quote_id c in
          Ok (Sca_challenge.Or_challenge.Challenge ch)
        | Ok q ->
          let%map.Deferred.Or_error r = execute_transfer t r ~quote_id:q.id in
          Sca_challenge.Or_challenge.Done (info_of r))
     | _ ->
       let%map.Deferred.Or_error r = refresh_transfer t r in
       Sca_challenge.Or_challenge.Done (info_of r))
  | None ->
    (match draft.direction, draft.status, Refs.account_parts from with
     | In, _, _ | _, (Awaiting_sca | Submitted | Pending | Settled), _ ->
       return (Or_error.error_string "only outgoing drafts can be initiated")
     | _, _, (Error _ as e) -> return (Or_error.map e ~f:(fun _ -> assert false))
     | Out, _, Ok (customer_id, account_id) ->
       track_customer t customer_id;
       let record ~quote_id ~fee ~status =
         { Transfer_record.id = draft.id
         ; account = from
         ; rail = draft.rail
         ; amount = draft.amount
         ; fee
         ; details = draft.details
         ; quote_id
         ; provider_ref = None
         ; status
         ; updated_at = now ()
         }
       in
       (match%bind start_transfer t ~customer_id ~account_id draft with
        | Error e ->
          (* Grid refuses a quote above the balance: the payment fails, not the call. *)
          if String.is_substring (Error.to_string_hum e) ~substring:"INSUFFICIENT"
          then (
            let%bind (_ : Transfer_record.t) =
              let r =
                record
                  ~quote_id:None
                  ~fee:(Money.Amount.zero (Money.Amount.currency draft.amount))
                  ~status:Draft
              in
              let%bind () = t.store.set_transfer r in
              fail_transfer t r Insufficient_funds
            in
            match%map t.store.find_transfer draft.id with
            | Some r -> Ok (Sca_challenge.Or_challenge.Done (info_of r))
            | None -> Error e)
          else return (Error e)
        | Ok (q, fee) ->
          (match q.status, q.sca_challenge with
           | "PENDING_AUTHORIZATION", Some c ->
             let r = record ~quote_id:(Some q.id) ~fee ~status:Awaiting_sca in
             let%bind () = t.store.set_transfer r in
             let%map ch = new_challenge t ~purpose:(Transfer draft.id) ~quote_id:q.id c in
             Ok (Sca_challenge.Or_challenge.Challenge ch)
           | _ ->
             let r = record ~quote_id:(Some q.id) ~fee ~status:Draft in
             let%bind () = t.store.set_transfer r in
             let%map.Deferred.Or_error r = execute_transfer t r ~quote_id:q.id in
             Sca_challenge.Or_challenge.Done (info_of r))))
;;

let transfer t id =
  match%bind t.store.find_transfer id with
  | None -> return (Or_error.error_s [%message "unknown transfer" (id : Transfer.Id.t)])
  | Some r ->
    let%map.Deferred.Or_error r = refresh_transfer t r in
    info_of r
;;

let cancel_transfer t id =
  match%bind t.store.find_transfer id with
  | None -> return (Or_error.error_s [%message "unknown transfer" (id : Transfer.Id.t)])
  | Some r when status_rank r.status >= 5 ->
    return (Or_error.error_s [%message "transfer already finished" (id : Transfer.Id.t)])
  | Some r ->
    let cancelled () =
      let r = { r with status = Cancelled; updated_at = now () } in
      let%map () = t.store.set_transfer r in
      publish
        t
        (event
           ~id:("cancel:" ^ Transfer.Id.to_string id)
           ~at:r.updated_at
           (Transfer
              { transfer = id
              ; provider_ref = Option.value r.provider_ref ~default:""
              ; update = Cancelled
              }));
      Ok (info_of r)
    in
    (match r.provider_ref with
     | None ->
       (* Never executed: the quote lapses at Grid on its own. *)
       cancelled ()
     | Some tx ->
       (match%bind lift (Grid_api.cancel_transaction t.api ~id:tx) with
        | Error _ as e -> return e
        | Ok _ -> cancelled ()))
;;

(* {2 Swaps} *)

let quote_swap t ~from ~to_ ~sell =
  match Refs.account_parts from, Refs.account_parts to_ with
  | (Error _ as e), _ | _, (Error _ as e) -> return (Or_error.map e ~f:(fun _ -> assert false))
  | Ok (a, _), Ok (b, _) when not (String.equal a b) ->
    return (Or_error.error_string "a swap moves between two accounts of one customer")
  | Ok (customer_id, source), Ok (_, destination) ->
    track_customer t customer_id;
    let open Deferred.Or_error.Let_syntax in
    let%bind amount = Deferred.return (Units.to_grid sell) in
    t.swaps <- t.swaps + 1;
    (* Unique per process and run; Grid's idempotency key is this id. *)
    let id =
      Swap.Id.of_string
        (sprintf "swp-%d-%d" (Time_ns.to_int_ns_since_epoch (now ())) t.swaps)
    in
    let%bind q =
      lift
        (Grid_api.create_quote
           t.api
           ~source_account_id:source
           ~destination:(Account { account_id = destination; payment_rail = None })
           ~locked:`Sending
           ~amount
           ~description:"conversion"
           ~idempotency_key:(Swap.Id.to_string id))
    in
    let%bind quote =
      Deferred.return
        (let open Or_error.Let_syntax in
         let%bind sell =
           Units.amount ~code:q.sending_code ~decimals:q.sending_decimals q.total_sending
         in
         let%bind fee =
           Units.amount ~code:q.sending_code ~decimals:q.sending_decimals q.fees_included
         in
         let%bind buy =
           Units.amount
             ~code:q.receiving_code
             ~decimals:q.receiving_decimals
             q.total_receiving
         in
         let%bind net = Money.Amount.sub sell fee in
         (* The price the customer got, from the amounts themselves rather than Grid's
            float rate (which is per smallest unit and fee-exclusive). *)
         let%bind price =
           if Money.Amount.is_positive net
           then Ok (Q.div (Money.Amount.to_q buy) (Money.Amount.to_q net))
           else Or_error.error_string "the fee takes the whole amount"
         in
         let%map market =
           Money.Rate.create
             ~base:(Money.Amount.currency sell)
             ~quote:(Money.Amount.currency buy)
             ~price
             ~at:(now ())
             ~source:"lightspark"
         in
         { Swap.Quote.id
         ; sell
         ; fee
         ; buy
         ; market
         ; spread_bps = 0
         ; created_at = Grid_time.parse_or ~default:(now ()) (Some q.created_at)
         ; expires_at =
             Grid_time.parse_or
               ~default:(Time_ns.add (now ()) (Time_ns.Span.of_min 1.))
               (Some q.expires_at)
         })
    in
    let%bind () =
      t.store.set_swap
        { Swap_record.id
        ; from
        ; to_
        ; sell = quote.sell
        ; fee = quote.fee
        ; buy = quote.buy
        ; quote_id = q.id
        ; expires_at = quote.expires_at
        ; executed = false
        }
      |> Deferred.ok
    in
    return quote
;;

let observe_swap_tx t (s : Swap_record.t) ~transaction_id =
  match transaction_id with
  | None -> return ()
  | Some id ->
    (match%bind lift (Grid_api.transaction t.api ~id) with
     | Ok tx -> observe_swap t s tx
     | Error e ->
       note_error t e;
       return ())
;;

let run_swap t (s : Swap_record.t) =
  match%bind
    Grid_api.execute_quote
      t.api
      ~id:s.quote_id
      ~idempotency_key:(Swap.Id.to_string s.id ^ ":execute")
  with
  | Error e when insufficient e ->
    publish
      t
      (event
         ~id:(sprintf "swap:%s:failed" (Swap.Id.to_string s.id))
         ~at:(now ())
         (Swap_failed { swap = s.id; reason = "insufficient funds" }));
    return (Ok (Sca_challenge.Or_challenge.Done ()))
  | Error e -> return (Error (Lc.Api_error.to_error e))
  | Ok q ->
    (match q.status, q.sca_challenge with
     | "PENDING_AUTHORIZATION", Some c ->
       let%map ch = new_challenge t ~purpose:(Swap s.id) ~quote_id:q.id c in
       Ok (Sca_challenge.Or_challenge.Challenge ch)
     | _ ->
       let s = { s with executed = true } in
       let%bind () = t.store.set_swap s in
       let%map () = observe_swap_tx t s ~transaction_id:q.transaction_id in
       Ok (Sca_challenge.Or_challenge.Done ()))
;;

let execute_swap t id =
  match%bind t.store.find_swap id with
  | None -> return (Or_error.error_s [%message "unknown swap" (id : Swap.Id.t)])
  | Some s when s.executed -> return (Ok (Sca_challenge.Or_challenge.Done ()))
  | Some s when Time_ns.( > ) (now ()) s.expires_at ->
    return (Or_error.error_s [%message "the quote expired" (id : Swap.Id.t)])
  | Some s -> run_swap t s
;;

(* {2 Confirming a challenge} *)

let attempts_left t id =
  max_attempts - Option.value (Hashtbl.find t.attempts id) ~default:0
;;

let wrong_code e =
  match (e : Lc.Api_error.t) with
  | Http { status = 400 | 401 | 403 | 422; code; _ } ->
    (match code with
     | Some c -> not (String.is_substring c ~substring:"EXPIRED")
     | None -> true)
  | _ -> false
;;

let confirm_sca t id ~code =
  match%bind t.store.find_challenge id with
  | None -> return (Or_error.error_s [%message "unknown SCA challenge" (id : Sca.Id.t)])
  | Some cr when cr.settled ->
    return (Ok (Sca_challenge.Result.Failed Sca.Failure.Cancelled))
  | Some cr when Time_ns.( > ) (now ()) cr.challenge.expires_at ->
    let%map () = t.store.set_challenge { cr with settled = true } in
    Ok (Sca_challenge.Result.Failed Sca.Failure.Expired)
  | Some cr ->
    (match%bind
       Grid_api.authorize_quote
         ?end_user_ip:t.config.end_user_ip
         t.api
         ~id:cr.quote_id
         ~code:(Sensitive.reveal code)
     with
     | Error e when wrong_code e ->
       Hashtbl.update t.attempts id ~f:(fun n -> Option.value n ~default:0 + 1);
       let left = attempts_left t id in
       if left <= 0
       then (
         let%map () = t.store.set_challenge { cr with settled = true } in
         Ok (Sca_challenge.Result.Failed Sca.Failure.Too_many_attempts))
       else return (Ok (Sca_challenge.Result.Wrong_code { attempts_left = left }))
     | Error e -> return (Error (Lc.Api_error.to_error e))
     | Ok q ->
       let%bind () = t.store.set_challenge { cr with settled = true } in
       (match q.status, cr.challenge.purpose with
        | "PENDING_AUTHORIZATION", _ ->
          (* Grid can chain challenges (a conversion, then the payout); the next one is
             handed out by a resend of the operation. *)
          return (Ok Sca_challenge.Result.Accepted)
        | _, Transfer transfer_id ->
          (match%bind t.store.find_transfer transfer_id with
           | None -> return (Ok Sca_challenge.Result.Accepted)
           | Some r ->
             let%map.Deferred.Or_error (_ : Transfer_record.t) =
               execute_transfer t r ~quote_id:q.id
             in
             Sca_challenge.Result.Accepted)
        | _, Swap swap_id ->
          (match%bind t.store.find_swap swap_id with
           | None -> return (Ok Sca_challenge.Result.Accepted)
           | Some s ->
             let%map.Deferred.Or_error (_ : unit Sca_challenge.Or_challenge.t) =
               run_swap t s
             in
             Sca_challenge.Result.Accepted)
        | _, (Standing_order _ | Card_details _) -> return (Ok Sca_challenge.Result.Accepted)))
;;

(* {2 Cards and standing orders: not offered by this adapter} *)

let no_cards () =
  return (Or_error.error_string "cards are not supported by the Grid adapter")
;;

let issue_virtual_card _t ~request_id:_ _customer ~account:_ = no_cards ()
let card _t (_ : Ids.Card_id.t) = no_cards ()
let cards _t (_ : Customer_ref.t) = no_cards ()
let set_card_status _t (_ : Ids.Card_id.t) (_ : Card_core.Card.Status.t) = no_cards ()
let set_card_limits _t (_ : Ids.Card_id.t) (_ : Card_core.Limits.t) = no_cards ()
let card_details_token _t (_ : Ids.Card_id.t) = no_cards ()

let create_standing_order _t ~from:_ (_ : Standing_order.t) =
  return
    (Or_error.error_string
       "Grid has no scheduled payments; run standing orders in the application")
;;

let cancel_standing_order _t (_ : Standing_order_ref.t) =
  return (Or_error.error_string "Grid has no scheduled payments")
;;

(* {2 Webhooks} *)

let events_of_webhook t (e : Lc.Webhook.Grid.event) =
  let captured = Queue.create () in
  t.captures <- captured :: t.captures;
  let finish () =
    t.captures <- List.filter t.captures ~f:(fun q -> not (phys_equal q captured));
    (* Ids already published are not published again, so a redelivery yields no
       events; the inbox would have dropped them anyway. *)
    Queue.to_list captured
  in
  let data () = Or_error.try_with (fun () -> Yojson.Safe.from_string e.data) in
  let%map result =
    match String.lsplit2 e.type_ ~on:'.' with
    | Some (("OUTGOING_PAYMENT" | "INCOMING_PAYMENT"), _) ->
      (match data () with
       | Error _ as err -> return err
       | Ok json ->
         let tx = Grid_api.Transaction.of_json json in
         Option.iter tx.customer_id ~f:(track_customer t);
         let%map () = observe_tx t tx in
         Ok ())
    | Some ("CUSTOMER", _) ->
      (match data () with
       | Error _ as err -> return err
       | Ok json ->
         let c = Grid_api.Customer.of_json json in
         track_customer t c.id;
         ignore (observe_customer t c : Customer.Kyc_status.t);
         return (Ok ()))
    | None when String.equal e.type_ "TEST" ->
      publish t (event ~id:("ping:" ^ e.id) ~at:(now ()) Ping);
      return (Ok ())
    | _ ->
      (* Account, card, verification and agent notices: nothing to normalize; the
         poller reads balances and KYC directly. *)
      return (Ok ())
  in
  let events = finish () in
  Or_error.map result ~f:(fun () -> events)
;;

let ingest_webhook t (request : Webhook.Request.t) =
  match t.config.webhook_public_key with
  | None ->
    return
      (Or_error.error_s
         [%message "no Grid webhook public key configured" ~variable:webhook_key_var])
  | Some public_key ->
    (match Webhook.Request.header request Lc.Webhook.Grid.signature_header with
     | None -> return (Or_error.error_string "missing X-Grid-Signature")
     | Some signature ->
       (match Lc.Webhook.Grid.verify ~public_key ~body:request.body ~signature with
        | Error _ as e -> return e
        | Ok e -> events_of_webhook t e))
;;

(* {2 Sandbox} *)

let sandbox_only t f =
  match%bind Lc.Grid.ensure_sandbox_or_live (Grid_api.grid t.api) with
  | Error e -> return (Error (Lc.Api_error.to_error e))
  | Ok () when Lc.Config.is_live (Grid_api.config t.api) ->
    return (Or_error.error_string "sandbox simulations are refused in live mode")
  | Ok () -> f ()
;;

let simulate_deposit t ~account ~rail:(_ : Rail.t) amount =
  sandbox_only t (fun () ->
    let open Deferred.Or_error.Let_syntax in
    let%bind customer_id, a = find_grid_account t account in
    track_customer t customer_id;
    let%bind () =
      if String.equal (Units.code (Money.Amount.currency amount)) a.balance.code
      then return ()
      else
        Deferred.Or_error.error_s
          [%message
            "a deposit is in the account's currency"
              ~account_currency:a.balance.code
              ~amount:(amount : Money.Amount.t)]
    in
    let%bind minor = Deferred.return (Units.to_minor ~decimals:a.balance.decimals amount) in
    t.deposits <- t.deposits + 1;
    (* The description comes back on the incoming transaction, which is how the deposit
       is found again: the fund call answers with the account, not the transaction. *)
    let description =
      sprintf
        "sandbox deposit %d %s"
        t.deposits
        (Time_ns.to_string_utc (now ()) |> String.filter ~f:Char.is_alphanum)
    in
    let%bind (_ : Grid_api.Internal_account.t) =
      lift (Grid_api.sandbox_fund t.api ~account_id:a.id ~amount:minor ~description)
    in
    let%bind tx =
      poll_until
        ~timeout:t.config.provisioning_timeout
        ~every:t.config.poll_interval
        (fun () ->
           let%map txs = lift (Grid_api.transactions t.api ~customer_id ~max_pages:1) in
           List.find txs ~f:(fun (tx : Grid_api.Transaction.t) ->
             String.equal tx.type_ "INCOMING"
             && Option.equal String.equal tx.description (Some description)))
      |> Deferred.map ~f:(Or_error.tag ~tag:"waiting for the deposit's transaction")
    in
    let%map () = Deferred.ok (observe_tx t tx) in
    Event.incoming_transfer_id ~provider_ref:tx.id)
;;

let simulate_kyc_decision t customer (decision : Sandbox.Kyc_decision.t) =
  sandbox_only t (fun () ->
    let id = Refs.customer_id customer in
    track_customer t id;
    match%map fetch_kyc t ~customer_id:id with
    | Error _ as e -> e
    | Ok status ->
      (match decision, status.status with
       | Approve, Approved -> Ok ()
       | Reject _, Rejected _ -> Ok ()
       | Request_resubmission _, Needs_resubmission _ -> Ok ()
       | _ ->
         Or_error.error_s
           [%message
             "the Grid sandbox decides KYC when the customer is created, by the last \
              three characters of the name (001 pending, 002 rejected, 003 unverified, \
              anything else approved); it cannot be changed afterwards"
               (decision : Sandbox.Kyc_decision.t)
               ~current:(status.status : Kyc_core.Status.t)]))
;;

let simulate_card_auth _t (_ : Ids.Card_id.t) (_ : Card_core.Merchant.t) = no_cards ()

let simulate_transfer_outcome _t (_ : Transfer.Id.t) (_ : Transfer_update.t) =
  return
    (Or_error.error_string
       "the Grid sandbox picks a payout's outcome from the last three digits of the \
        payee's account number (002 fails, 003 is slow, 005 is returned, 010-013 are \
        rejected); there is no call to change it afterwards")
;;

let ping t =
  match%bind lift (Grid_api.send_test_webhook t.api) with
  | Error _ as e -> return e
  | Ok status ->
    (* Grid delivers the test event to the dashboard's URL, which a local run does not
       receive; publish the Ping here, like the delivery would, once Grid reports the
       attempt. *)
    publish
      t
      (event
         ~id:(sprintf "ping:test:%d:%d" status (Time_ns.to_int_ns_since_epoch (now ())))
         ~at:(now ())
         Ping);
    return (Ok ())
;;
