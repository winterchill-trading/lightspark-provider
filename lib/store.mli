(** What the adapter remembers between calls, in domain types.

    Grid keeps our customer id on the customer ([platformCustomerId]) and our beneficiary
    id on each external account ([platformAccountId]), and takes an [Idempotency-Key] on
    every create, so creating twice is already safe at Grid. What it cannot answer is
    "which quote and transaction belong to our transfer id" and "which quote is our swap";
    those links live here, with the SCA challenge a quote is waiting on.

    A service persists these in its own database by implementing {!t} (the transfer and
    swap records have stable binary forms); {!memory} serves tests, the CLI and the
    conformance run, and forgets everything when the process exits. Every write is keyed,
    so repeating one is harmless. *)

open! Core
open Async_kernel
open Banking_provider
open Payments_core

module Transfer_record : sig
  type t =
    { id : Transfer.Id.Stable.V1.t
    ; account : Account_ref.Stable.V1.t
    ; rail : Rail.Stable.V2.t
    ; amount : Money.Amount.Stable.V1.t (** what the payee receives *)
    ; fee : Money.Amount.Stable.V1.t (** in the account's currency *)
    ; details : Transfer.Details.Stable.V2.t
    ; quote_id : string option
    ; provider_ref : string option (** Grid's transaction id, once executed *)
    ; status : Transfer.Status.t
    ; updated_at : Utc_time.Stable.V1.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Challenge_record : sig
  type t =
    { challenge : Sca_challenge.t
    ; quote_id : string (** the quote Grid's challenge authorizes *)
    ; settled : bool (** answered (accepted, or failed for good) *)
    }
  [@@deriving sexp, compare, equal]
end

module Swap_record : sig
  type t =
    { id : Swap.Id.Stable.V1.t
    ; from : Account_ref.Stable.V1.t
    ; to_ : Account_ref.Stable.V1.t
    ; sell : Money.Amount.Stable.V1.t
    ; fee : Money.Amount.Stable.V1.t
    ; buy : Money.Amount.Stable.V1.t
    ; quote_id : string
    ; expires_at : Utc_time.Stable.V1.t
    ; executed : bool
    }
  [@@deriving bin_io, sexp, compare, equal]
end

type t =
  { find_transfer : Transfer.Id.t -> Transfer_record.t option Deferred.t
  ; find_transfer_by_ref : string -> Transfer_record.t option Deferred.t
  (** by Grid transaction id *)
  ; find_transfer_by_quote : string -> Transfer_record.t option Deferred.t
  ; set_transfer : Transfer_record.t -> unit Deferred.t
  ; find_challenge : Sca.Id.t -> Challenge_record.t option Deferred.t
  ; set_challenge : Challenge_record.t -> unit Deferred.t
  ; find_swap : Swap.Id.t -> Swap_record.t option Deferred.t
  ; find_swap_by_quote : string -> Swap_record.t option Deferred.t
  ; set_swap : Swap_record.t -> unit Deferred.t
  }

(** Hash tables in this process. *)
val memory : unit -> t
