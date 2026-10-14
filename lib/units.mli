(** Grid currencies and amounts in {!Money} terms.

    Grid sends every amount as an integer in the currency's smallest unit together with
    the currency's code and number of decimals
    ([{"amount": 1000, "currency": {"code": "USD", "decimals": 2}}]). {!Money} keeps its
    own registry of exponents; when the two disagree the amount is rescaled here, exactly,
    and a conversion that would drop digits fails instead of rounding.

    Stablecoins map to the untagged {!Money.Currency.usdc} and {!Money.Currency.usdt}:
    Grid holds them in custody and deposits arrive on several chains. [USDB] (the embedded
    wallet's dollar token) and any payout currency {!Money} does not know yet are
    registered on first use with Grid's decimals. *)

open! Core

(** The {!Money.Currency.t} for a Grid currency code and its decimals. *)
val currency : code:string -> decimals:int -> Money.Currency.t Or_error.t

(** Grid's code for a currency: the {!Money} code without a network tag ([USDC@polygon] is
    [USDC]). *)
val code : Money.Currency.t -> string

(** [amount ~code ~decimals 1050] is 10.50 USD for [code = "USD"], [decimals = 2]. *)
val amount : code:string -> decimals:int -> int -> Money.Amount.t Or_error.t

(** The amount in Grid's smallest unit with [decimals] places; fails when the amount has
    more digits than that or does not fit an int. *)
val to_minor : decimals:int -> Money.Amount.t -> int Or_error.t

(** [to_minor] with the decimals {!Money} uses for the currency, which is what Grid uses
    for every currency it holds (USD 2, USDC/USDT/USDB 6, BTC 8). *)
val to_grid : Money.Amount.t -> int Or_error.t
