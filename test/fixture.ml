open! Core
open! Async
module Lc = Lightspark_client

let read path = In_channel.read_all ("fixtures/" ^ path)
let json path = Yojson.Safe.from_string (read path)

let response ?(status = 200) path =
  { Lc.Transport.Response.status
  ; headers = [ "x-request-id", "req-test" ]
  ; body = read path
  }
;;

let fake_transport ?(verbose = false) routes =
  let routes = List.map routes ~f:(fun (key, responses) -> key, ref responses) in
  fun (request : Lc.Transport.Request.t) ->
    let meth = Sexp.to_string [%sexp (request.meth : Lc.Transport.Meth.t)] in
    let path = Uri.path request.uri in
    if verbose then printf "%s %s\n" meth path;
    let answer =
      List.find_map routes ~f:(fun ((m, suffix), responses) ->
        if String.equal m meth && String.is_suffix path ~suffix
        then (
          match !responses with
          | [] -> None
          | [ last ] -> Some last
          | first :: rest ->
            responses := rest;
            Some first)
        else None)
    in
    return
      (Ok
         (Option.value
            answer
            ~default:
              { Lc.Transport.Response.status = 404
              ; headers = []
              ; body = {|{"code":"NOT_FOUND","reason":"no route in the test"}|}
              }))
;;

let config =
  Lc.Config.create ~client_id:"test-client-id" ~client_secret:"test-client-secret" ()
;;

let api ?verbose routes =
  Lightspark_provider.Grid_api.create
    ~transport:(fake_transport ?verbose routes)
    ~policy:Lc.Transport.Retry.no_retry
    ~log:ignore
    config
;;
