open! Core
open! Async
open Lightspark_provider

let show r = print_s [%sexp (r : Money.Amount.t Or_error.t)]

let%expect_test "Grid amounts in money units" =
  show (Units.amount ~code:"USD" ~decimals:2 1050);
  show (Units.amount ~code:"USDC" ~decimals:6 10_000_000);
  (* Grid's dollar token of the embedded wallet is registered on first use. *)
  show (Units.amount ~code:"USDB" ~decimals:6 1_500_000);
  (* A payout currency the registry lacks is registered with Grid's decimals. *)
  show (Units.amount ~code:"XOF" ~decimals:0 5000);
  show (Units.amount ~code:"not-a-code" ~decimals:2 1);
  [%expect
    {|
    (Ok "10.50 USD")
    (Ok "10.000000 USDC")
    (Ok "1.500000 USDB")
    (Ok "5000 XOF")
    (Error ("unknown currency" not-a-code))
    |}];
  return ()
;;

let%expect_test "rescaling never drops digits" =
  let usdc = Money.Amount.of_decimal_string Money.Currency.usdc "1.234567" |> ok_exn in
  print_s [%sexp (Units.to_minor ~decimals:6 usdc : int Or_error.t)];
  print_s [%sexp (Units.to_minor ~decimals:2 usdc : int Or_error.t)];
  print_s [%sexp (Units.to_minor ~decimals:8 usdc : int Or_error.t)];
  [%expect
    {|
    (Ok 1234567)
    (Error
     ("amount has more digits than the target unit" (minor 1234567) (from 6)
      (to_ 2)))
    (Ok 123456700)
    |}];
  return ()
;;

let%test_unit "to_grid and amount round-trip for the currencies Grid holds" =
  let currencies = Money.Currency.[ usd; usdc; usdt; eur; btc ] in
  Quickcheck.test
    (let open Quickcheck.Generator.Let_syntax in
     let%bind c = Quickcheck.Generator.of_list currencies in
     let%map minor = Int.gen_incl (-1_000_000_000_000) 1_000_000_000_000 in
     Money.Amount.of_minor_units_int c minor)
    ~sexp_of:Money.Amount.sexp_of_t
    ~f:(fun a ->
      let c = Money.Amount.currency a in
      let back =
        Units.to_grid a
        |> Or_error.bind ~f:(fun minor ->
          Units.amount ~code:(Units.code c) ~decimals:(Money.Currency.exponent c) minor)
      in
      [%test_result: Money.Amount.t Or_error.t] back ~expect:(Ok a))
;;
