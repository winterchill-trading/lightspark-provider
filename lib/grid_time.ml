open! Core

let parse s =
  Or_error.try_with (fun () -> Time_ns.of_string_with_utc_offset s)
  |> Or_error.tag ~tag:("not a Grid timestamp: " ^ s)
;;

let parse_or ~default = function
  | None -> default
  | Some s -> Result.ok (parse s) |> Option.value ~default
;;
