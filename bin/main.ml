(* Read-only views of a Grid platform through the adapter: a customer's KYC state and
   accounts, and the fee for a payout. Credentials come from LIGHTSPARK_* variables. *)

open! Core
open! Async
open Banking_provider
module Adapter = Lightspark_provider.Adapter

let adapter () = Adapter.of_env () |> Or_error.ok_exn

let customer_command =
  Command.async_or_error
    ~summary:"KYC state and accounts of a Grid customer (by its Customer:... id)"
    (let%map_open.Command id = flag "-id" (required string) ~doc:"ID Grid customer id" in
     fun () ->
       let t = adapter () in
       let customer = Lightspark_provider.Refs.customer id in
       let%bind.Deferred.Or_error kyc = Adapter.kyc_status t customer in
       let%map.Deferred.Or_error accounts = Adapter.accounts t customer in
       print_s
         [%message
           ""
             ~kyc:(kyc.status : Kyc_core.Status.t)
             ~steps:
               (kyc.steps
                : (Kyc_core.Verification.Step.t * Kyc_core.Verification.State.t) list)
             ~accounts:
               (List.map accounts ~f:(fun (a : Account.t) ->
                  a.id, a.currency, List.length a.addresses)
                : (Account_ref.t * Money.Currency.t * int) list)])
;;

let fee_command =
  Command.async_or_error
    ~summary:"Fee and debit for paying an amount out of an account"
    (let%map_open.Command account =
       flag "-account" (required string) ~doc:"REF account (<customer id>/<account id>)"
     and amount =
       flag
         "-amount"
         (required string)
         ~doc:"AMOUNT what the payee receives, e.g. '30.00 EUR'"
     and instant = flag "-instant" no_arg ~doc:" SEPA Instant instead of SEPA" in
     fun () ->
       let t = adapter () in
       let%bind.Deferred.Or_error amount =
         Deferred.return (Money.Amount.of_string_or_error amount)
       in
       let rail : Payments_core.Rail.t = if instant then Sepa_instant else Sepa_credit in
       let%map.Deferred.Or_error q =
         Adapter.quote_fee t ~from:(Account_ref.of_string account) ~rail amount
       in
       print_s [%sexp (q : Transfer_info.Fee_quote.t)])
;;

let () =
  Command_unix.run
    (Command.group
       ~summary:"banking-provider adapter over the Lightspark Grid API (read-only tools)"
       [ "customer", customer_command; "fee", fee_command ])
;;
