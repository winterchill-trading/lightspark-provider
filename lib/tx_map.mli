(** Grid transactions as transfer updates and deposits.

    Grid reports every movement as a transaction with a [type] ([INCOMING], [OUTGOING]), a
    [status] and, once failed, a [failureReason]. The adapter publishes one event per
    transaction and status, with the id [tx:<transaction id>:<STATUS>], so the poller and
    a webhook delivery that see the same change publish the same event.

    {v
      OUTGOING status / failureReason          Transfer_update
      CREATED, PENDING                         Submitted
      PENDING_AUTHORIZATION                    nothing (the SCA challenge is the signal)
      PROCESSING                               Pending
      COMPLETED                                Settled
      FAILED  PAYOUT_RETURNED, REFUNDED        Returned MS03
      FAILED  ACCOUNT_INVALID                  Rejected AC01
      FAILED  ACCOUNT_CANNOT_RECEIVE           Rejected AC06
      FAILED  COMPLIANCE_REJECTED              Rejected RR04
      FAILED  LIMIT_EXCEEDED                   Rejected AM02
      FAILED  COUNTERPARTY_POST_TX_FAILED      Rejected MS03
      REJECTED                                 Rejected MS03 (or the reason above)
      FAILED  SCA_NOT_COMPLETED                Failed Sca_failed
      FAILED  QUOTE_EXPIRED, EXPIRED           Failed Expired
      FAILED  anything else                    Failed (Provider_error <reason>)
    v}

    An incoming transaction becomes an [Incoming_transfer] (id [tx:<id>:in], settled when
    [COMPLETED]); its completion is also published as [Transfer Settled] and a later
    failure as [Transfer Returned] (after settlement) or [Rejected], all on our id
    {!Banking_provider.Event.incoming_transfer_id}. Grid sends no ISO 20022 reason codes;
    [MS03] stands in where none of the above fits. *)

open! Core
open Banking_provider
open Payments_core

val event_id : Grid_api.Transaction.t -> Event_id.t

(** [None] for statuses that say nothing to the transfer (see above). *)
val outgoing_update : Grid_api.Transaction.t -> Transfer_update.t option

(** On-chain when Grid reports a hash or a network; SEPA, SEPA Instant, ACH (as PPD), Same
    Day ACH, RTP, Fedwire ([WIRE]) or Lightning when the payment rail says so;
    [Intraledger] otherwise: FedNow, the other countries' rails and Grid's own book
    transfers (sandbox credits, conversions) have no {!Payments_core.Rail.t}. *)
val rail : Grid_api.Transaction.t -> Rail.t

val details : Grid_api.Transaction.t -> Transfer.Details.t

(** The events for an incoming transaction to [account], with their ids. *)
val incoming : account:Account_ref.t -> Grid_api.Transaction.t -> Event.t list Or_error.t

(** An amount Grid reported, or an error naming the field that was missing. *)
val money_of : Grid_api.Amount.t option -> what:string -> Money.Amount.t Or_error.t

(** The fee Grid charged on an outgoing transaction, in the sent currency (zero when it
    reports none). *)
val fee : Grid_api.Transaction.t -> Money.Amount.t Or_error.t
