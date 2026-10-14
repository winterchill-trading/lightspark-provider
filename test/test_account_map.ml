open! Core
open! Async
open Banking_provider
open Lightspark_provider

let accounts () =
  Fixture.json "internal-accounts.json"
  |> Yojson.Safe.Util.member "data"
  |> Yojson.Safe.Util.to_list
  |> List.map ~f:Grid_api.Internal_account.of_json
;;

let%expect_test "a customer's internal accounts as provider accounts" =
  List.iter (accounts ()) ~f:(fun a ->
    match Account_map.account ~customer_id:"Customer:c" a with
    | Error e -> print_s [%sexp (e : Error.t)]
    | Ok acc ->
      print_s
        [%message
          ""
            ~type_:(a.type_ : string)
            ~currency:(acc.currency : Money.Currency.t)
            ~status:(acc.status : Ledger.Account_status.t)
            ~addresses:(acc.addresses : Account.Address.t list)]);
  [%expect
    {|
    ((type_ INTERNAL_CRYPTO) (currency USDT) (status Open)
     (addresses
      ((Crypto
        (address
         ((network Ethereum)
          (address 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed)))
        (memo ()))
       (Crypto
        (address ((network Tron) (address TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t)))
        (memo ()))
       (Crypto
        (address
         ((network Arbitrum)
          (address 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed)))
        (memo ()))
       (Crypto
        (address
         ((network Plasma) (address 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed)))
        (memo ())))))
    ((type_ INTERNAL_CRYPTO) (currency USDC) (status Open)
     (addresses
      ((Crypto
        (address
         ((network Solana) (address So11111111111111111111111111111111111111112)))
        (memo ()))
       (Crypto
        (address
         ((network Base) (address 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed)))
        (memo ()))
       (Crypto
        (address
         ((network Ethereum)
          (address 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed)))
        (memo ()))
       (Crypto
        (address
         ((network Polygon) (address 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed)))
        (memo ()))
       (Crypto
        (address
         ((network Arbitrum)
          (address 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed)))
        (memo ())))))
    ((type_ INTERNAL_FIAT) (currency USD) (status Open)
     (addresses
      ((Us_account
        ((routing 000000000) (account_number 000000001) (account_type Checking))))))
    ((type_ EMBEDDED_WALLET) (currency USDB) (status Open) (addresses ()))
    |}];
  return ()
;;

let%expect_test "balances and US bank details" =
  List.iter (accounts ()) ~f:(fun a ->
    let r = Refs.account ~customer_id:"Customer:c" ~account_id:a.id in
    match Account_map.balance r a ~at:Time_ns.epoch with
    | Error e -> print_s [%sexp (e : Error.t)]
    | Ok b ->
      print_s
        [%message
          ""
            ~available:(b.available : Money.Amount.t)
            ~held:(b.held : Money.Amount.t)
            ~us:
              (Option.is_some
                 (List.find_map (Account_map.addresses a.funding) ~f:(function
                   | Account.Address.Us_account u -> Some u
                   | _ -> None))
               : bool)]);
  [%expect
    {|
    ((available "0.000000 USDT") (held "0.000000 USDT") (us false))
    ((available "0.000000 USDC") (held "0.000000 USDC") (us false))
    ((available "100.00 USD") (held "0.00 USD") (us true))
    ((available "0.000000 USDB") (held "0.000000 USDB") (us false))
    |}];
  return ()
;;

let%expect_test "account statuses" =
  List.iter
    [ "ACTIVE"; "PENDING"; "FROZEN"; "CLOSED"; "FAILED"; "NEW_VALUE" ]
    ~f:(fun s -> print_s [%message s ~_:(Account_map.status s : Ledger.Account_status.t)]);
  [%expect
    {|
    (ACTIVE Open)
    (PENDING Open)
    (FROZEN Frozen)
    (CLOSED Closed)
    (FAILED Closed)
    (NEW_VALUE Open)
    |}];
  return ()
;;

let%expect_test "account references carry the customer" =
  let r = Refs.account ~customer_id:"Customer:c" ~account_id:"InternalAccount:a" in
  print_s [%sexp (Refs.account_parts r : (string * string) Or_error.t)];
  print_s
    [%sexp
      (Refs.account_parts (Account_ref.of_string "nope") : (string * string) Or_error.t)];
  [%expect
    {|
    (Ok (Customer:c InternalAccount:a))
    (Error ("not a Grid account reference" nope))
    |}];
  return ()
;;
