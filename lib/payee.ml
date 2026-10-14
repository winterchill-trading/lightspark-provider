open! Core
open Payments_core

type t =
  | External of
      { currency : string
      ; account_info : (Yojson.Safe.t[@sexp.opaque])
      ; payment_rail : string option
      ; platform_account_id : string
      }
  | Internal of { account_id : string }
[@@deriving sexp_of]

let wallet_type (n : Network.t) =
  match n with
  | Ethereum -> Some "ETHEREUM_WALLET"
  | Polygon -> Some "POLYGON_WALLET"
  | Solana -> Some "SOLANA_WALLET"
  | Tron -> Some "TRON_WALLET"
  | Base -> Some "BASE_WALLET"
  | Arbitrum -> Some "ARBITRUM_WALLET"
  | Plasma -> Some "PLASMA_WALLET"
  | Spark -> Some "SPARK_WALLET"
  | Bitcoin | Bitcoin_testnet -> None
;;

let individual ~name ~country =
  `Assoc
    [ "beneficiaryType", `String "INDIVIDUAL"
    ; "fullName", `String name
    ; "countryOfResidence", `String country
    ]
;;

let bank_account (b : Beneficiary.t) ~payment_rail =
  match b.destination with
  | Bank_account { iban; bic } ->
    let iban_s = Iban.to_string iban in
    Some
      (External
         { currency = "EUR"
         ; account_info =
             `Assoc
               (List.filter_opt
                  [ Some ("accountType", `String "EUR_ACCOUNT")
                  ; Some ("iban", `String iban_s)
                  ; Option.map bic ~f:(fun b -> "swiftCode", `String (Bic.to_string b))
                  ; Some
                      ( "beneficiary"
                      , individual ~name:b.name ~country:(String.prefix iban_s 2) )
                  ])
         ; payment_rail
         ; platform_account_id = Beneficiary.Id.to_string b.id
         })
  | Us_account a ->
    Some
      (External
         { currency = "USD"
         ; account_info =
             `Assoc
               [ "accountType", `String "USD_ACCOUNT"
               ; "accountNumber", `String a.account_number
               ; "routingNumber", `String (Aba.to_string a.routing)
               ; ( "bankAccountType"
                 , `String
                     (match a.account_type with
                      | Checking -> "CHECKING"
                      | Savings -> "SAVINGS") )
               ; ( "beneficiary"
                 , `Assoc
                     [ "beneficiaryType", `String "INDIVIDUAL"
                     ; "fullName", `String b.name
                     ] )
               ]
         ; payment_rail
         ; platform_account_id = Beneficiary.Id.to_string b.id
         })
  | _ -> None
;;

let us_rail (r : Rail.t) =
  match r with
  | Ach { same_day = false; _ } -> Some "ACH"
  | Ach { same_day = true; _ } -> Some "ACH_SAME_DAY"
  | Rtp -> Some "RTP"
  | Fedwire -> Some "WIRE"
  | _ -> None
;;

let of_transfer (tr : Transfer.t) ~payee_country =
  let currency = Units.code (Money.Amount.currency tr.amount) in
  match tr.counterparty with
  | External _ -> Or_error.error_string "only outgoing transfers have a payee"
  | Beneficiary b ->
    let platform_account_id = Beneficiary.Id.to_string b.id in
    (match b.destination, tr.rail with
     | Bank_account _, (Sepa_credit | Sepa_instant) ->
       if not (String.equal currency "EUR")
       then
         Or_error.error_s
           [%message "a SEPA payout delivers EUR" ~amount_currency:(currency : string)]
       else (
         let payment_rail =
           Some
             (match tr.rail with
              | Sepa_instant -> "SEPA_INSTANT"
              | _ -> "SEPA")
         in
         Or_error.of_option
           (bank_account b ~payment_rail)
           ~error:(Error.of_string "not a bank account"))
     | Us_account _, ((Ach _ | Rtp | Fedwire) as rail) ->
       if not (String.equal currency "USD")
       then
         Or_error.error_s
           [%message "US rails deliver USD" ~amount_currency:(currency : string)]
       else
         Or_error.of_option
           (bank_account b ~payment_rail:(us_rail rail))
           ~error:(Error.of_string "not a US account")
     | Crypto { address; memo = _ }, Onchain network ->
       (match wallet_type network with
        | None ->
          Or_error.error_s
            [%message "Grid has no wallet account on this network" (network : Network.t)]
        | Some account_type ->
          Ok
            (External
               { currency
               ; account_info =
                   `Assoc
                     [ "accountType", `String account_type
                     ; "address", `String (Crypto_address.address address)
                     ; "beneficiary", individual ~name:b.name ~country:payee_country
                     ]
               ; payment_rail = None
               ; platform_account_id
               }))
     | Lightning target, Lightning ->
       let field =
         match target with
         | Invoice i -> Ok ("invoice", i.raw)
         | Address { user; domain } -> Ok ("lightningAddress", user ^ "@" ^ domain)
         | Lnurl _ ->
           Or_error.error_string "Grid pays Lightning invoices and addresses, not LNURL"
       in
       Or_error.map field ~f:(fun (k, v) ->
         External
           { currency
           ; account_info = `Assoc [ "accountType", `String "LIGHTNING"; k, `String v ]
           ; payment_rail = None
           ; platform_account_id
           })
     | Internal { account }, Intraledger ->
       (match String.rsplit2 account ~on:'/' with
        | Some (_, account_id) -> Ok (Internal { account_id })
        | None -> Ok (Internal { account_id = account }))
     | _, rail ->
       Or_error.error_s
         [%message
           "destination and rail do not match a Grid payout"
             (rail : Rail.t)
             ~destination:(b.destination : Beneficiary.Destination.t)])
;;
