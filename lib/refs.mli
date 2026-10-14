(** Provider-side references built from Grid ids.

    A Grid customer is [Customer:<uuid>] and is used as the
    {!Banking_provider.Customer_ref.t} as is. Grid has no endpoint that reads one internal
    account by id (only lists per customer), so an account reference carries its owner:
    [<customer id>/<internal account id>]. Grid ids never contain [/]. *)

open! Core
open Banking_provider

val customer : string -> Customer_ref.t
val customer_id : Customer_ref.t -> string
val account : customer_id:string -> account_id:string -> Account_ref.t

(** The customer id and the internal account id; fails on a reference this module did not
    make. *)
val account_parts : Account_ref.t -> (string * string) Or_error.t
