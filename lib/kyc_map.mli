(** Grid's KYC state in kyc-core terms.

    Grid reports one [kycStatus] per customer and, only where the customer's jurisdiction
    requires it, a [contactVerification] object with an e-mail and a phone state. Identity
    checks (document and liveness) happen inside Grid's own flow, at creation on a
    regulated platform or through a hosted link, so both steps follow the status.

    {v
      Grid kycStatus      kyc-core status          Identity_document, Liveness
      UNVERIFIED          Created                  Pending
      PENDING             Verifying                Sent
      APPROVED            Approved                 Verified
      REJECTED            Rejected                 Failed
      HOLD                Needs_resubmission       Failed ("on hold")

      contactVerification.email / .phone
      PENDING             Email / Mobile Sent
      VERIFIED            Email / Mobile Verified
      absent              Pending: the jurisdiction does not ask for it
    v}

    Grid says nothing about which data a [HOLD] wants, so it asks for the identity fields
    again. *)

open! Core
open Banking_provider

val status : string option -> Kyc_core.Status.t

(** The status and steps as {!Customer.Kyc_status.t}. Steps whose state has not changed
    kind since [previous] keep their earlier value (and so their verification time); new
    verifications are stamped [at], since Grid does not say when they happened. *)
val kyc_status
  :  Customer_ref.t
  -> ?previous:Customer.Kyc_status.t
  -> Grid_api.Customer.t
  -> at:Time_ns.t
  -> Customer.Kyc_status.t

(** The transitions from [from] to [to_] ([Created] to [Approved] is [Submit] then
    [Approve]); empty when they are equal or nothing leads there. *)
val transitions
  :  from:Kyc_core.Status.t
  -> to_:Kyc_core.Status.t
  -> Kyc_core.Status.Transition.t list

(** The events between two observations of one customer: each step that changed kind,
    then the status transitions. Ids are derived from the change
    ([kyc:<customer>:step:<Step>:<State>], [kyc:<customer>:<From>:<Transition>]), so a
    poll and a webhook that see the same change produce the same event. *)
val events
  :  previous:Customer.Kyc_status.t
  -> current:Customer.Kyc_status.t
  -> at:Time_ns.t
  -> Event.t list
