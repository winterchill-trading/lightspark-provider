open! Core
open! Async
open Banking_provider
module Adapter = Lightspark_provider.Adapter
module Suite = Conformance.Make (Adapter) (Adapter)

let person = Live_person.person
let email_for = Live_person.email_for
let suite_config ~run_id = { (Conformance.Config.usd ~run_id) with person }

let adapter ~(suite : Conformance.Config.t) =
  Adapter.of_env
    ~config:
      { Adapter.Config.default with
        email_for
      ; (* The suite's timeout decides, not the adapter's longer default. *)
        provisioning_timeout = suite.timeout
      ; poll_interval = Time_ns.Span.max suite.poll_interval (Time_ns.Span.of_ms 500.)
      }
    ()
;;

let print_result name took = function
  | Ok () -> Core.printf "ok    %s (%s)\n%!" name (Time_ns.Span.to_short_string took)
  | Error e ->
    Core.printf
      "FAIL  %s (%s)\n      %s\n%!"
      name
      (Time_ns.Span.to_short_string took)
      (String.prefix (Error.to_string_hum e) 600)
;;

let conformance () =
  let run_id =
    sprintf "lp%d" (Time_ns.to_int_ns_since_epoch (Time_ns.now ()) / 1_000_000_000)
  in
  let suite = suite_config ~run_id in
  match adapter ~suite with
  | Error e ->
    Core.eprint_s [%sexp (e : Error.t)];
    Stdlib.exit 1
  | Ok adapter ->
    let only = Sys.getenv "LIGHTSPARK_CONFORMANCE_ONLY" in
    let scenarios =
      Suite.scenarios suite
      |> List.filter ~f:(fun (s : Suite.scenario) ->
        match only with
        | None -> true
        | Some sub -> String.is_substring s.name ~substring:sub)
    in
    let%map results =
      Deferred.List.map ~how:`Sequential scenarios ~f:(fun s ->
        let started = Time_ns.now () in
        let%map result =
          Monitor.try_with_or_error ~extract_exn:true (fun () -> s.run adapter)
          >>| Or_error.join
        in
        print_result s.name (Time_ns.diff (Time_ns.now ()) started) result;
        result)
    in
    List.iter (Adapter.background_errors adapter) ~f:(fun e ->
      Core.printf "background: %s\n" (String.prefix (Error.to_string_hum e) 300));
    let failed = List.count results ~f:Result.is_error in
    Core.printf
      "conformance on the Grid sandbox: %d passed, %d failed\n%!"
      (List.length results - failed)
      failed
;;

let () =
  let live = Option.equal String.equal (Sys.getenv "LIGHTSPARK_LIVE_TESTS") (Some "1") in
  let credentials = Result.is_ok (Lightspark_client.Config.of_env ()) in
  if not (live && credentials)
  then
    (* Core's printer: the Async scheduler never starts on this path. *)
    Core.print_endline
      "lightspark-provider conformance skipped (set LIGHTSPARK_CLIENT_ID, \
       LIGHTSPARK_CLIENT_SECRET and LIGHTSPARK_LIVE_TESTS=1)"
  else
    Command_unix.run
      (Command.async
         ~summary:"conformance suite on the Grid sandbox"
         (Command.Param.return conformance))
;;
