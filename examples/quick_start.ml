(* Onboard a customer on the Grid sandbox, open its USD account, credit it through the
   sandbox and print the balance. Needs LIGHTSPARK_CLIENT_ID and LIGHTSPARK_CLIENT_SECRET
   for a sandbox platform; creates sandbox data. *)

open! Core
open! Async
module Adapter = Lightspark_provider.Adapter

let person =
  let open Kyc_core in
  { Person.given_name = Pii.create "Ada"
  ; family_name = Pii.create "Example"
  ; date_of_birth = Pii.create (Date.create_exn ~y:1990 ~m:Jan ~d:15)
  ; nationality = Pii.create (Country.of_string "US")
  ; residential_address =
      Pii.create
        { Address.line1 = "1 Example Street"
        ; line2 = None
        ; city = "Seattle"
        ; region = Some "WA"
        ; postal_code = Some "98101"
        ; country = Country.of_string "US"
        }
  ; (* Grid wants a deliverable address; the adapter tags it per customer. *)
    email = Pii.create "you@your-domain.example"
  ; mobile = Pii.create "+12065550100"
  }
;;

let main () =
  let open Deferred.Or_error.Let_syntax in
  let%bind adapter = Deferred.return (Adapter.of_env ()) in
  let%bind customer =
    Adapter.create_customer
      adapter
      ~customer_id:(Kyc_core.Customer_id.of_string "example-customer-1")
      ~person
  in
  (* Grid opens the account itself a moment after the customer; this waits for it. *)
  let%bind usd = Adapter.open_account adapter customer.id Money.Currency.usd in
  let%bind (_ : Payments_core.Transfer.Id.t) =
    Adapter.simulate_deposit
      adapter
      ~account:usd.id
      ~rail:Intraledger
      (Money.Amount.of_decimal_string Money.Currency.usd "25.00" |> Or_error.ok_exn)
  in
  let%map balance = Adapter.balance adapter usd.id in
  print_s [%message "available" ~_:(balance.available : Money.Amount.t)]
;;

let () =
  Command_unix.run
    (Command.async_or_error
       ~summary:"Grid sandbox quick start"
       (Command.Param.return main))
;;
