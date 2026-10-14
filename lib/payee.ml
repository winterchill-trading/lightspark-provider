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
  | Bitcoin | Bitcoin_testnet -> None
;;

let individual ~name ~country =
  `Assoc
    [ "beneficiaryType", `String "INDIVIDUAL"
    ; "fullName", `String name
    ; "countryOfResidence", `String country
    ]
;;

let of_transfer (tr : Transfer.t) ~payee_country =
  let currency = Units.code (Money.Amount.currency tr.amount) in
  match tr.counterparty with
  | External _ -> Or_error.error_string "only outgoing transfers have a payee"
  | Beneficiary b ->
    let platform_account_id = Beneficiary.Id.to_string b.id in
    (match b.destination, tr.rail with
     | Bank_account { iban; bic }, (Sepa_credit | Sepa_instant) ->
       if not (String.equal currency "EUR")
       then
         Or_error.error_s
           [%message "a SEPA payout delivers EUR" ~amount_currency:(currency : string)]
       else (
         let iban_s = Iban.to_string iban in
         let info =
           `Assoc
             (List.filter_opt
                [ Some ("accountType", `String "EUR_ACCOUNT")
                ; Some ("iban", `String iban_s)
                ; Option.map bic ~f:(fun b -> "swiftCode", `String (Bic.to_string b))
                ; Some
                    ( "beneficiary"
                    , individual ~name:b.name ~country:(String.prefix iban_s 2) )
                ])
         in
         Ok
           (External
              { currency
              ; account_info = info
              ; payment_rail =
                  Some
                    (match tr.rail with
                     | Sepa_instant -> "SEPA_INSTANT"
                     | _ -> "SEPA")
              ; platform_account_id
              }))
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
         | Lnurl _ -> Or_error.error_string "Grid pays Lightning invoices and addresses, not LNURL"
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
