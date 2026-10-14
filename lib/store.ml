open! Core
open Async_kernel
open Banking_provider
open Payments_core

module Transfer_record = struct
  type t =
    { id : Transfer.Id.Stable.V1.t
    ; account : Account_ref.Stable.V1.t
    ; rail : Rail.Stable.V1.t
    ; amount : Money.Amount.Stable.V1.t
    ; fee : Money.Amount.Stable.V1.t
    ; details : Transfer.Details.t
    ; quote_id : string option
    ; provider_ref : string option
    ; status : Transfer.Status.t
    ; updated_at : Utc_time.Stable.V1.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Challenge_record = struct
  type t =
    { challenge : Sca_challenge.t
    ; quote_id : string
    ; settled : bool
    }
  [@@deriving sexp, compare, equal]
end

module Swap_record = struct
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
  ; find_transfer_by_quote : string -> Transfer_record.t option Deferred.t
  ; set_transfer : Transfer_record.t -> unit Deferred.t
  ; find_challenge : Sca.Id.t -> Challenge_record.t option Deferred.t
  ; set_challenge : Challenge_record.t -> unit Deferred.t
  ; find_swap : Swap.Id.t -> Swap_record.t option Deferred.t
  ; find_swap_by_quote : string -> Swap_record.t option Deferred.t
  ; set_swap : Swap_record.t -> unit Deferred.t
  }

let memory () =
  let transfers = Hashtbl.create (module Transfer.Id) in
  let by_ref = Hashtbl.create (module String) in
  let by_quote = Hashtbl.create (module String) in
  let challenges = Hashtbl.create (module Sca.Id) in
  let swaps = Hashtbl.create (module Swap.Id) in
  let swaps_by_quote = Hashtbl.create (module String) in
  let set tbl key data = Hashtbl.set tbl ~key ~data in
  let via index k = Option.bind (Hashtbl.find index k) ~f:(Hashtbl.find transfers) in
  { find_transfer = (fun k -> return (Hashtbl.find transfers k))
  ; find_transfer_by_ref = (fun r -> return (via by_ref r))
  ; find_transfer_by_quote = (fun q -> return (via by_quote q))
  ; set_transfer =
      (fun (r : Transfer_record.t) ->
        set transfers r.id r;
        Option.iter r.provider_ref ~f:(fun p -> set by_ref p r.id);
        Option.iter r.quote_id ~f:(fun q -> set by_quote q r.id);
        return ())
  ; find_challenge = (fun k -> return (Hashtbl.find challenges k))
  ; set_challenge =
      (fun (r : Challenge_record.t) -> return (set challenges r.challenge.id r))
  ; find_swap = (fun k -> return (Hashtbl.find swaps k))
  ; find_swap_by_quote =
      (fun q ->
        return (Option.bind (Hashtbl.find swaps_by_quote q) ~f:(Hashtbl.find swaps)))
  ; set_swap =
      (fun (r : Swap_record.t) ->
        set swaps r.id r;
        set swaps_by_quote r.quote_id r.id;
        return ())
  }
;;
