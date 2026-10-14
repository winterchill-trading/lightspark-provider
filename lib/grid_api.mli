(** The Grid endpoints and object views the adapter needs beyond what
    [lightspark-client]'s [Grid] module covers: external accounts, quotes with a payment
    rail and an SCA challenge, quote authorization, balance changes, contact verification,
    hosted KYC links, test webhooks and transaction cancellation.

    Requests go through [lightspark-client]'s transport, retry policy, Basic credentials
    and redaction, so they behave like the client's own (retries only when idempotent,
    every create carries an [Idempotency-Key]). Objects are decoded leniently: only the
    fields used here are read and enum-like values stay strings, so a new server value
    does not break decoding. Writes that can move money first pass the client's sandbox
    check ([Grid.ensure_sandbox_or_live]). *)

open! Core
open! Async
module Lc := Lightspark_client

type t

val create
  :  ?transport:Lc.Transport.t
  -> ?policy:Lc.Transport.Retry.policy
  -> ?log:(Sexp.t -> unit)
  -> Lc.Config.t
  -> t

val config : t -> Lc.Config.t

(** The client's own Grid handle on the same transport, for the endpoints it covers. *)
val grid : t -> Lc.Grid.t

type 'a response := 'a Lc.Api_error.result Deferred.t

(** {2 Views} *)

module Amount : sig
  type t =
    { minor : int (** in the currency's smallest unit *)
    ; code : string
    ; decimals : int
    }
  [@@deriving sexp, compare, equal]

  val of_json : Yojson.Safe.t -> t
  val to_money : t -> Money.Amount.t Or_error.t
end

module Funding_instruction : sig
  (** How to pay into an internal account: a US or EUR bank account, a SWIFT account or a
      wallet address on a network. *)
  type t =
    { account_type : string (** [USD_ACCOUNT], [SOLANA_WALLET], ... *)
    ; address : string option (** wallets *)
    ; asset_type : string option (** [USDC], [USDT], ... for wallets *)
    ; account_number : string option
    ; routing_number : string option
    ; iban : string option
    ; swift_code : string option
    ; bank_name : string option
    ; reference : string option (** memo the depositor must include *)
    ; payment_rails : string list
    }
  [@@deriving sexp, compare, equal]
end

module Internal_account : sig
  type t =
    { id : string
    ; customer_id : string option
    ; type_ : string (** [INTERNAL_FIAT], [INTERNAL_CRYPTO], [EMBEDDED_WALLET], ... *)
    ; status : string
    ; balance : Amount.t (** available: excludes pending and held funds *)
    ; total_balance : Amount.t option (** including pending and held funds *)
    ; funding : Funding_instruction.t list
    ; created_at : string
    }
  [@@deriving sexp, compare, equal]

  val of_json : Yojson.Safe.t -> t
end

module Customer : sig
  type t =
    { id : string
    ; platform_customer_id : string option
    ; kyc_status : string option (** [UNVERIFIED], [PENDING], [APPROVED], ... *)
    ; email_verification : string option
    (** [contactVerification.email], only where the jurisdiction requires it *)
    ; phone_verification : string option
    ; created_at : string
    }
  [@@deriving sexp, compare, equal]

  val of_json : Yojson.Safe.t -> t
end

module External_account : sig
  type t =
    { id : string
    ; customer_id : string option
    ; status : string (** [PENDING], [ACTIVE], [UNDER_REVIEW], ... *)
    ; currency : string
    ; platform_account_id : string option
    ; account_type : string option (** [EUR_ACCOUNT], [LIGHTNING], ... *)
    ; beneficiary_verification : string option
    (** [MATCHED], [NOT_MATCHED], [PARTIAL_MATCH], ... where the rail checks names *)
    }
  [@@deriving sexp, compare, equal]

  val of_json : Yojson.Safe.t -> t
end

module Sca_challenge : sig
  type t =
    { id : string
    ; expires_at : string
    ; factor : string (** [SMS_OTP], [PASSKEY], [TOTP] *)
    ; available_factors : string list
    ; purpose : string option (** [CURRENCY_CONVERSION], [PAYOUT], ... informational *)
    }
  [@@deriving sexp, compare, equal]
end

module Quote : sig
  type t =
    { id : string
    ; status : string
    (** [PENDING], [PENDING_AUTHORIZATION], [PROCESSING], [COMPLETED], [FAILED], [EXPIRED] *)
    ; created_at : string
    ; expires_at : string
    ; sending_code : string
    ; sending_decimals : int
    ; receiving_code : string
    ; receiving_decimals : int
    ; total_sending : int (** fees included *)
    ; total_receiving : int
    ; exchange_rate : float
    (** sending smallest units per receiving smallest unit, fees excluded *)
    ; fees_included : int (** in the sending currency *)
    ; transaction_id : string option
    ; sca_challenge : Sca_challenge.t option
    }
  [@@deriving sexp, compare, equal]

  val of_json : Yojson.Safe.t -> t
end

module Transaction : sig
  type t =
    { id : string
    ; status : string
    (** [CREATED], [PENDING], [PENDING_AUTHORIZATION], [PROCESSING], [COMPLETED],
        [REJECTED], [FAILED], [REFUNDED], [EXPIRED] *)
    ; type_ : string (** [INCOMING], [OUTGOING], [CARD] *)
    ; direction : string option
    ; customer_id : string option
    ; description : string option
    ; sent : Amount.t option
    ; received : Amount.t option
    ; fees : int option (** sending currency *)
    ; quote_id : string option
    ; failure_reason : string option
    ; payment_rail : string option
    ; source_type : string option
    ; source_account_id : string option
    ; destination_type : string option
    ; destination_account_id : string option
    ; tx_hash : string option
    (** an on-chain leg's hash, from either side's rail details *)
    ; network : string option
    ; created_at : string option
    ; updated_at : string option
    ; settled_at : string option
    }
  [@@deriving sexp, compare, equal]

  val of_json : Yojson.Safe.t -> t
end

module Balance_change : sig
  type t =
    { id : string
    ; transaction_id : string option
    ; amount : Amount.t (** signed: money in is positive *)
    ; effective_at : string
    }
  [@@deriving sexp, compare, equal]

  val of_json : Yojson.Safe.t -> t
end

module Kyc_link : sig
  type t =
    { url : string
    ; expires_at : string
    ; token : string option
    }
  [@@deriving sexp_of]
end

(** {2 Customers} *)

(** [GET /customers?platformCustomerId=]: Grid keeps our id on the customer, so a create
    can be made idempotent without our own store. *)
val find_customer : t -> platform_customer_id:string -> Customer.t option response

val customer : t -> id:string -> Customer.t response

module New_customer : sig
  type t =
    { platform_customer_id : string
    ; full_name : string
    ; birth_date : Date.t
    ; nationality : string (** ISO 3166-1 alpha-2 *)
    ; email : string
    ; address_line1 : string
    ; address_line2 : string option
    ; city : string
    ; region : string option
    ; postal_code : string
    ; country : string
    }
  [@@deriving sexp_of]

  val to_json : t -> Yojson.Safe.t
end

(** [POST /customers] for an individual; refuses outside sandbox unless [Live]. *)
val create_customer : t -> New_customer.t -> idempotency_key:string -> Customer.t response

(** [PATCH /customers/{id}] with the name, birth date, nationality and address only (an
    e-mail change on a customer with an embedded wallet needs a signed retry flow). *)
val update_customer : t -> id:string -> New_customer.t -> unit response

(** [POST /customers/{id}/verify-email] or [verify-phone]: sends a code. *)
val start_contact_verification : t -> id:string -> [ `Email | `Phone ] -> unit response

(** The [/confirm] sub-route with the code the customer received. *)
val confirm_contact_verification
  :  t
  -> id:string
  -> [ `Email | `Phone ]
  -> code:string
  -> Customer.t response

(** [POST /customers/{id}/kyc-link]: a hosted identity verification session. *)
val kyc_link : t -> id:string -> Kyc_link.t response

(** {2 Accounts} *)

(** Every internal account of a customer, all pages. *)
val customer_accounts : t -> customer_id:string -> Internal_account.t list response

(** [GET /internal-accounts/{id}/balance-changes] for [\[start, stop)], all pages. [stop]
    must not be in the future. *)
val balance_changes
  :  t
  -> account_id:string
  -> start:Time_ns.t
  -> stop:Time_ns.t
  -> Balance_change.t list response

(** [POST /sandbox/internal-accounts/{id}/fund]; sandbox keys only. *)
val sandbox_fund
  :  t
  -> account_id:string
  -> amount:int
  -> description:string
  -> Internal_account.t response

(** {2 External accounts} *)

val external_accounts : t -> customer_id:string -> External_account.t list response

(** [POST /customers/external-accounts]. [account_info] is Grid's [accountInfo] object
    (built by {!Payee}); [platform_account_id] is our beneficiary id. *)
val create_external_account
  :  t
  -> customer_id:string
  -> currency:string
  -> platform_account_id:string
  -> account_info:Yojson.Safe.t
  -> idempotency_key:string
  -> External_account.t response

(** {2 Quotes and transactions} *)

module Destination : sig
  type t =
    | Account of
        { account_id : string (** internal or external *)
        ; payment_rail : string option
        }
end

(** [POST /quotes] from an internal account. [locked] is the side whose amount is fixed.
    [sender_info] fills [senderCustomerInfo], the sender fields a corridor asks for (a
    quote without one fails with [MISSING_MANDATORY_USER_INFO]). *)
val create_quote
  :  ?description:string
  -> ?remittance:string
  -> ?sender_info:(string * string) list
  -> ?immediately_execute:bool
  -> t
  -> source_account_id:string
  -> destination:Destination.t
  -> locked:[ `Sending | `Receiving ]
  -> amount:int
  -> idempotency_key:string
  -> Quote.t response

val quote : t -> id:string -> Quote.t response
val execute_quote : t -> id:string -> idempotency_key:string -> Quote.t response

(** [POST /quotes/{id}/authorize] with a one-time code. *)
val authorize_quote
  :  ?end_user_ip:string
  -> t
  -> id:string
  -> code:string
  -> Quote.t response

val transaction : t -> id:string -> Transaction.t response

(** [GET /transactions?customerId=], newest first, up to [max_pages] pages of 100. *)
val transactions
  :  ?max_pages:int
  -> t
  -> customer_id:string
  -> Transaction.t list response

(** [POST /transactions/{id}/cancel]: a bank transfer not yet submitted to its rail. *)
val cancel_transaction : t -> id:string -> Transaction.t response

(** {2 Rates and webhooks} *)

module Rate : sig
  type t =
    { source : string
    ; destination : string
    ; destination_decimals : int
    ; rail : string option
    ; exchange_rate : float (** sending smallest units per receiving smallest unit *)
    ; fee_total : int option (** sending currency, for [sending_amount] *)
    ; sending_amount : int option
    ; receiving_amount : int option
    ; min_sending : int option
    ; max_sending : int option
    }
  [@@deriving sexp, compare, equal]
end

val rates
  :  ?sending_amount:int
  -> t
  -> source:string
  -> destination:string
  -> Rate.t list response

(** [POST /webhooks/test]: Grid signs and delivers a [TEST] event to the platform's
    configured URL and returns that endpoint's HTTP status. *)
val send_test_webhook : t -> int response
