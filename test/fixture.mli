(** Recorded (redacted) and documented Grid bodies, and a transport that answers from
    them. *)

open! Core
open! Async
module Lc := Lightspark_client

(** Contents of [fixtures/<path>]. *)
val read : string -> string

val json : string -> Yojson.Safe.t

(** A response with status 200 (or [status]) whose body is the fixture [path]. *)
val response : ?status:int -> string -> Lc.Transport.Response.t

(** A transport answering each request from the first route whose method and path suffix
    match ([("POST", "/quotes")]); a route with several responses gives them in order and
    then repeats the last. Prints [METHOD path] for every request when [verbose]. Unrouted
    requests get a 404. *)
val fake_transport
  :  ?verbose:bool
  -> ((string * string) * Lc.Transport.Response.t list) list
  -> Lc.Transport.t

(** A sandbox config with dummy credentials. *)
val config : Lc.Config.t

(** {!Lightspark_provider.Grid_api.t} over [fake_transport] without retries. *)
val api
  :  ?verbose:bool
  -> ((string * string) * Lc.Transport.Response.t list) list
  -> Lightspark_provider.Grid_api.t
