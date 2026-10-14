open! Core

let register ~code ~decimals ~kind =
  Money.Currency.register ~code ~exponent:decimals ~kind ()
;;

let stablecoins = [ "USDB" ]

let currency ~code ~decimals =
  match Money.Currency.of_string_or_error code with
  | Ok c -> Ok c
  | Error _ when List.mem stablecoins code ~equal:String.equal ->
    register ~code ~decimals ~kind:Crypto
  | Error _ when String.length code = 3 && String.for_all code ~f:Char.is_uppercase ->
    (* A payout currency (XAF, BWP, ...) the registry does not carry yet. *)
    register ~code ~decimals ~kind:Fiat
  | Error _ as e -> e
;;

let code c = Money.Currency.code c
let pow10 n = Z.pow (Z.of_int 10) n

let rescale minor ~from ~to_ =
  if from = to_
  then Ok minor
  else if to_ > from
  then Ok (Z.mul minor (pow10 (to_ - from)))
  else (
    let q, r = Z.div_rem minor (pow10 (from - to_)) in
    if Z.equal r Z.zero
    then Ok q
    else
      Or_error.error_s
        [%message
          "amount has more digits than the target unit"
            ~minor:(Z.to_string minor)
            (from : int)
            (to_ : int)])
;;

let amount ~code ~decimals minor =
  let open Or_error.Let_syntax in
  let%bind currency = currency ~code ~decimals in
  let%map minor =
    rescale (Z.of_int minor) ~from:decimals ~to_:(Money.Currency.exponent currency)
  in
  Money.Amount.of_minor_units currency minor
;;

let to_minor ~decimals a =
  let open Or_error.Let_syntax in
  let currency = Money.Amount.currency a in
  let%bind z =
    rescale
      (Money.Amount.minor_units a)
      ~from:(Money.Currency.exponent currency)
      ~to_:decimals
  in
  if Z.fits_int z
  then Ok (Z.to_int z)
  else Or_error.error_s [%message "amount too large" ~amount:(Z.to_string z)]
;;

let to_grid a = to_minor ~decimals:(Money.Currency.exponent (Money.Amount.currency a)) a
