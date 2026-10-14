open! Core
open! Async
open Payments_core
open Lightspark_provider

let now = Time_ns.epoch

let details ~rail destination : Transfer.Details.t option =
  match (rail : Rail.t) with
  | Sepa_credit | Sepa_instant ->
    let iban = Iban.of_string destination |> ok_exn in
    let party name = { Iso20022.Party.name; iban; bic = None; address = None } in
    Some
      (Sepa
         (Sepa.Details.create
            ~payment_id:(Iso20022.Payment_id.create ~end_to_end_id:"tr-1" () |> ok_exn)
            ~debtor:(party "Ada Sandbox")
            ~creditor:(party "Erika Payee")
            ()))
  | Onchain _ ->
    let person name account =
      { Travel_rule.Person.name
      ; account
      ; identification = Some (Customer_number "c-1")
      ; lei = None
      }
    in
    Some
      (Onchain
         { travel_rule =
             Some
               { originator = person "Ada Sandbox" "Customer:c"
               ; beneficiary = person "Erika Payee" destination
               ; counterparty_wallet = Self_hosted { ownership_verified = true }
               }
         ; tx_hash = None
         ; block_hash = None
         ; confirmations = 0
         ; finalized = false
         })
  | _ -> None
;;

let draft ~rail ~amount destination =
  let open Or_error.Let_syntax in
  let%bind beneficiary =
    Beneficiary.create
      ~id:(Beneficiary.Id.of_string "ben-1")
      ~owner:"Customer:c"
      ~name:"Erika Payee"
      ~rail
      ~now
      destination
  in
  Transfer.draft
    ~id:(Transfer.Id.of_string "tr-1")
    ~rail
    ~account:(Ledger.Account_id.of_string "app:1")
    ~beneficiary
    ~amount
    ?details:(details ~rail destination)
    ~now
    ()
;;

let show d =
  match d with
  | Error e -> print_s [%sexp "draft refused", (e : Error.t)]
  | Ok d ->
    (match Payee.of_transfer d ~payee_country:"US" with
     | Error e -> print_s [%sexp (e : Error.t)]
     | Ok (Internal { account_id }) -> print_s [%message "internal" account_id]
     | Ok (External { currency; account_info; payment_rail; platform_account_id }) ->
       print_s
         [%message
           currency (payment_rail : string option) platform_account_id];
       print_endline (Yojson.Safe.to_string account_info))
;;

let amount c s = Money.Amount.of_decimal_string c s |> ok_exn

let%expect_test "beneficiaries as Grid external accounts" =
  show (draft ~rail:Sepa_credit ~amount:(amount Money.Currency.eur "30.00") "DE89370400440532013000");
  show (draft ~rail:Sepa_instant ~amount:(amount Money.Currency.eur "30.00") "FR1420041010050500013M02606");
  show
    (draft
       ~rail:(Onchain Ethereum)
       ~amount:(amount Money.Currency.usdc "5.000000")
       "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed");
  show (draft ~rail:Lightning ~amount:(amount Money.Currency.btc "0.00010000") "satoshi@example.com");
  show (draft ~rail:Intraledger ~amount:(amount Money.Currency.usdc "1.000000") "Customer:c/InternalAccount:b");
  [%expect {|
    (EUR (payment_rail (SEPA)) ben-1)
    {"accountType":"EUR_ACCOUNT","iban":"DE89370400440532013000","beneficiary":{"beneficiaryType":"INDIVIDUAL","fullName":"Erika Payee","countryOfResidence":"DE"}}
    (EUR (payment_rail (SEPA_INSTANT)) ben-1)
    {"accountType":"EUR_ACCOUNT","iban":"FR1420041010050500013M02606","beneficiary":{"beneficiaryType":"INDIVIDUAL","fullName":"Erika Payee","countryOfResidence":"FR"}}
    (USDC (payment_rail ()) ben-1)
    {"accountType":"ETHEREUM_WALLET","address":"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed","beneficiary":{"beneficiaryType":"INDIVIDUAL","fullName":"Erika Payee","countryOfResidence":"US"}}
    (BTC (payment_rail ()) ben-1)
    {"accountType":"LIGHTNING","lightningAddress":"satoshi@example.com"}
    (internal InternalAccount:b)
    |}];
  return ()
;;

let%expect_test "what Grid cannot pay" =
  (* SEPA delivers euros only. *)
  show (draft ~rail:Sepa_credit ~amount:(amount Money.Currency.usd "30.00") "DE89370400440532013000");
  (* No Bitcoin on-chain wallet account type. *)
  show
    (draft
       ~rail:(Onchain Bitcoin)
       ~amount:(amount Money.Currency.btc "0.00010000")
       "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq");
  [%expect {|
    ("draft refused" ("SEPA transfers are in EUR" (amount "30.00 USD")))
    ("Grid has no wallet account on this network" (network Bitcoin))
    |}];
  return ()
;;
