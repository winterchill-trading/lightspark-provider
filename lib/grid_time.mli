(** Grid timestamps: RFC 3339 in UTC with up to microseconds
    ([2026-10-13T20:03:27.414891Z]). *)

open! Core

val parse : string -> Time_ns.t Or_error.t

(** [parse], or [default] for a missing or malformed value. *)
val parse_or : default:Time_ns.t -> string option -> Time_ns.t
