open! Core
open! Async
open Lightspark_provider

(* The records a service persists through its own [Store.t]: a changed digest means stored
   rows no longer read back, so it is a version decision. *)
let%expect_test "stored record digests" =
  print_endline [%bin_digest: Store.Transfer_record.t];
  print_endline [%bin_digest: Store.Swap_record.t];
  [%expect
    {|
    06bacdf88ba3a208a74d7a86e84cb7fd
    4fab3e5d685740fb6c69cdfe6e30d407
    |}];
  return ()
;;
