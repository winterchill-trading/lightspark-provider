open! Core
open Banking_provider

let customer = Customer_ref.of_string
let customer_id = Customer_ref.to_string

let account ~customer_id ~account_id =
  Account_ref.of_string (customer_id ^ "/" ^ account_id)
;;

let account_parts r =
  let s = Account_ref.to_string r in
  match String.lsplit2 s ~on:'/' with
  | Some (c, a) when (not (String.is_empty c)) && not (String.is_empty a) -> Ok (c, a)
  | _ -> Or_error.error_s [%message "not a Grid account reference" s]
;;
