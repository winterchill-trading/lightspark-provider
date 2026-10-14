open! Core

let person =
  let open Kyc_core in
  { Person.given_name = Pii.create "Ada"
  ; family_name = Pii.create "Sandbox"
  ; date_of_birth = Pii.create (Date.create_exn ~y:1990 ~m:Jan ~d:15)
  ; nationality = Pii.create (Country.of_string "US")
  ; residential_address =
      Pii.create
        { Address.line1 = "1 Test Street"
        ; line2 = None
        ; city = "Seattle"
        ; region = Some "WA"
        ; postal_code = Some "98101"
        ; country = Country.of_string "US"
        }
  ; email = Pii.create "hello@winterchill.xyz"
  ; mobile = Pii.create "+12065550100"
  }
;;

let email_for customer_id ~email:_ =
  let tag =
    String.filter_map (Kyc_core.Customer_id.to_string customer_id) ~f:(fun c ->
      if Char.is_alphanum c || Char.equal c '-' then Some (Char.lowercase c) else None)
  in
  sprintf "hello+sandbox-%s@winterchill.xyz" tag
;;
