(** {!Banking_provider.Provider.S} and {!Banking_provider.Sandbox.S} over the Lightspark
    Grid API ([lightspark-client]).

    {b Scope.} Customers and their KYC state, the accounts Grid opens for each customer
    (USD and the stablecoins the platform supports), payouts from them to bank accounts in
    other currencies (cross-border, with Grid's FX quote), to wallets and to Lightning,
    conversions between a customer's own accounts as swaps, statements from Grid's balance
    changes, and webhooks. Cards and standing orders are not offered: those calls return
    an error. US domestic bank payouts (ACH, RTP, wire) need a rail and a beneficiary
    format payments-core does not have yet; {!us_bank_details} exposes the USD account's
    routing and account number for deposits.

    {b Ids.} A customer is the Grid customer ([Customer:<uuid>]) and carries our id as
    [platformCustomerId], so [create_customer] looks it up before creating. An account is
    [<customer id>/<internal account id>] ({!Refs}). A transfer's id is the Grid quote's
    [Idempotency-Key]; the quote and the transaction it creates are linked in a
    {!Store.t}.

    {b Payouts.} A transfer is a Grid quote from the account to an external account Grid
    holds for the payee (created once per beneficiary and currency), with the
    {e receiving} amount locked: the draft's amount is what the payee gets, and the fee
    and the debit are in the account's currency. Customers outside SCA regions get no
    challenge and the quote is executed at once; otherwise the quote waits in
    [PENDING_AUTHORIZATION] and its challenge becomes a
    {!Banking_provider.Sca_challenge.t} answered with {!confirm_sca}.

    {b Events.} Grid posts webhooks to the URL configured in its dashboard, signed with
    the platform's P-256 key; a service passes each delivery to {!ingest_webhook}. Without
    a public URL the adapter polls instead: while anything is subscribed to {!events} it
    reads, every [poll_interval], the KYC state and the latest transactions of every
    customer it has seen. Both paths derive the same event ids from Grid's data
    ({!Kyc_map}, {!Tx_map}), so an inbox applies each change once whichever path saw it
    first.

    {b Sandbox.} Grid has no explicit sandbox flag; [lightspark-client] treats a platform
    whose UMA domain contains [sandbox] as one and refuses money-moving writes elsewhere
    unless the config is [Live]. The {!Banking_provider.Sandbox.S} calls also refuse
    [Live] configs. *)

open! Core
open Async
open Banking_provider

module Config : sig
  type t =
    { poll_interval : Time_ns.Span.t
    ; provisioning_timeout : Time_ns.Span.t
    (** how long [open_account] waits for Grid to open the account and [simulate_deposit]
        waits for the credit's transaction *)
    ; email_for : Kyc_core.Customer_id.t -> email:string -> string
    (** the e-mail registered at Grid, which must be deliverable and is best unique per
        customer *)
    ; payee_country : string
    (** a wallet payee's country of residence, which Grid asks for and a crypto address
        does not tell *)
    ; end_user_ip : string option (** sent with SCA authorizations *)
    ; webhook_public_key : Lightspark_client.P256.public_key option
    ; transactions_pages : int
    (** pages of 100 the poller and the statement fallback read per customer *)
    ; purpose_of_payment : string option
    (** sent as [PURPOSE_OF_PAYMENT] with payouts to external accounts, which some
        corridors (USD to EUR among them) require; one of Grid's [PurposeOfPayment] values *)
    }

  (** Polls every 3 s, waits up to 2 minutes for provisioning, tags the person's e-mail
      with the customer id ([local+<id>@domain]), US payees, no IP, no webhook key, 3
      pages, [GOODS_OR_SERVICES]. *)
  val default : t

  (** [tagged_email id ~email] is [local+<id>@domain]; characters outside letters, digits
      and [-] are dropped from the tag. *)
  val tagged_email : Kyc_core.Customer_id.t -> email:string -> string
end

type t

val create : ?config:Config.t -> ?store:Store.t -> Grid_api.t -> t

(** Name of the variable holding the platform's webhook public key (PEM, newlines may be
    written as [\n]). *)
val webhook_key_var : string

(** [create] from [LIGHTSPARK_*] variables (see lightspark-client's [Config]) and
    {!webhook_key_var}. Sandbox unless [~live:true]. *)
val of_env : ?config:Config.t -> ?store:Store.t -> ?live:bool -> unit -> t Or_error.t

val api : t -> Grid_api.t

include Provider.S with type t := t
include Sandbox.S with type t := t

(** {2 Grid-specific} *)

(** The US bank details (ABA routing and account number, the memo reference) to fund a USD
    account by ACH or wire; [None] for other accounts. *)
val us_bank_details
  :  t
  -> Account_ref.t
  -> Account_map.Us_bank.t option Or_error.t Deferred.t

(** Failures inside the poller, which has no caller to return them to. *)
val background_errors : t -> Error.t list
