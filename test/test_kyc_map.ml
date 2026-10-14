open! Core
open! Async
open Banking_provider
open Lightspark_provider

let at = Time_ns.of_string_with_utc_offset "2026-10-14T06:00:00Z"

let customer ?email ?phone kyc : Grid_api.Customer.t =
  { id = "Customer:1"
  ; platform_customer_id = Some "c-1"
  ; kyc_status = kyc
  ; email_verification = email
  ; phone_verification = phone
  ; created_at = ""
  }
;;

let%expect_test "Grid KYC statuses" =
  List.iter
    [ None; Some "UNVERIFIED"; Some "PENDING"; Some "APPROVED"; Some "REJECTED"; Some "HOLD" ]
    ~f:(fun s ->
      print_s [%message (s : string option) ~status:(Kyc_map.status s : Kyc_core.Status.t)]);
  [%expect
    {|
    ((s ()) (status Created))
    ((s (UNVERIFIED)) (status Created))
    ((s (PENDING)) (status Verifying))
    ((s (APPROVED)) (status Approved))
    ((s (REJECTED)) (status (Rejected "rejected by the provider")))
    ((s (HOLD))
     (status
      (Needs_resubmission
       (Given_name Family_name Date_of_birth Nationality Residential_address))))
    |}];
  return ()
;;

let%expect_test "an approval seen for the first time: steps, then Submit and Approve" =
  let c = customer ~email:"VERIFIED" (Some "APPROVED") in
  let ref_ = Refs.customer c.id in
  let previous = Customer.Kyc_status.initial ref_ in
  let current = Kyc_map.kyc_status ref_ ~previous c ~at in
  print_s [%sexp (current.tier : Kyc_core.Tier.t)];
  List.iter (Kyc_map.events ~previous ~current ~at) ~f:(fun e ->
    print_s [%message (e.id : Event_id.t) ~kind:(Event.Kind.name e.kind)]);
  (* The same observation again publishes nothing. *)
  let again = Kyc_map.kyc_status ref_ ~previous:current c ~at:(Time_ns.add at Time_ns.Span.hour) in
  print_s [%sexp (List.length (Kyc_map.events ~previous:current ~current:again ~at) : int)];
  [%expect
    {|
    T0
    ((e.id kyc:Customer:1:step:Email:Verified) (kind Kyc))
    ((e.id kyc:Customer:1:step:Identity_document:Verified) (kind Kyc))
    ((e.id kyc:Customer:1:step:Liveness:Verified) (kind Kyc))
    ((e.id kyc:Customer:1:Created:Submit) (kind Kyc))
    ((e.id kyc:Customer:1:Verifying:Approve) (kind Kyc))
    0
    |}];
  return ()
;;

let%expect_test "transitions between any two statuses" =
  let open Kyc_core.Status in
  List.iter
    [ Created, Approved
    ; Verifying, Rejected "no"
    ; Approved, Needs_resubmission [ Email ]
    ; Approved, Approved
    ; Rejected "no", Approved
    ]
    ~f:(fun (from, to_) ->
      print_s [%sexp (Kyc_map.transitions ~from ~to_ : Transition.t list)]);
  [%expect
    {|
    (Submit Approve)
    ((Reject no))
    ((Request_resubmission (Email)))
    ()
    ()
    |}];
  return ()
;;
