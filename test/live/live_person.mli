(** The synthetic customer both live runs use. *)

(** A US resident whose name has no numeric suffix, so the Grid sandbox approves it at
    creation. *)
val person : Kyc_core.Person.t

(** [hello+sandbox-<customer id>@winterchill.xyz]: deliverable, unique per customer. *)
val email_for : Kyc_core.Customer_id.t -> email:string -> string
