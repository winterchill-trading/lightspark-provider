open! Core
open Banking_provider
module Status = Kyc_core.Status
module Verification = Kyc_core.Verification

let identity_fields : Kyc_core.Person.Field.t list =
  [ Given_name; Family_name; Date_of_birth; Nationality; Residential_address ]
;;

let status (s : string option) : Status.t =
  match s with
  | Some "PENDING" -> Verifying
  | Some "APPROVED" -> Approved
  | Some "REJECTED" -> Rejected "rejected by the provider"
  | Some "HOLD" -> Needs_resubmission identity_fields
  | Some "UNVERIFIED" | Some _ | None -> Created
;;

let same_kind (a : Verification.State.t) (b : Verification.State.t) =
  match a, b with
  | Pending, Pending | Sent, Sent | Verified _, Verified _ | Expired, Expired -> true
  | Failed x, Failed y -> String.equal x y
  | _ -> false
;;

let identity_state (s : string option) ~at : Verification.State.t =
  match s with
  | Some "PENDING" -> Sent
  | Some "APPROVED" -> Verified at
  | Some "REJECTED" -> Failed "rejected by the provider"
  | Some "HOLD" -> Failed "on hold"
  | _ -> Pending
;;

let contact_state (s : string option) ~at : Verification.State.t =
  match s with
  | Some "VERIFIED" -> Verified at
  | Some "PENDING" -> Sent
  | _ -> Pending
;;

let kyc_status customer ?previous (c : Grid_api.Customer.t) ~at =
  let observed : (Verification.Step.t * Verification.State.t) list =
    [ Email, contact_state c.email_verification ~at
    ; Mobile, contact_state c.phone_verification ~at
    ; Identity_document, identity_state c.kyc_status ~at
    ; Liveness, identity_state c.kyc_status ~at
    ]
  in
  let keep step state =
    match previous with
    | None -> state
    | Some (p : Customer.Kyc_status.t) ->
      (match List.Assoc.find p.steps step ~equal:Verification.Step.equal with
       | Some old when same_kind old state -> old
       | _ -> state)
  in
  let with_steps =
    List.fold observed ~init:(Customer.Kyc_status.initial customer) ~f:(fun acc (step, state) ->
      Customer.Kyc_status.with_step acc step (keep step state))
  in
  { with_steps with status = status c.kyc_status }
;;

let transitions ~(from : Status.t) ~(to_ : Status.t) : Status.Transition.t list =
  match from, to_ with
  | Created, Verifying | Needs_resubmission _, Verifying -> [ Submit ]
  | (Created | Needs_resubmission _), Approved -> [ Submit; Approve ]
  | Verifying, Approved -> [ Approve ]
  | Created, Needs_resubmission fs -> [ Submit; Request_resubmission fs ]
  | (Verifying | Approved), Needs_resubmission fs -> [ Request_resubmission fs ]
  | Created, Rejected r -> [ Submit; Reject r ]
  | (Verifying | Needs_resubmission _), Rejected r -> [ Reject r ]
  | _ -> []
;;

let status_name (s : Status.t) =
  match s with
  | Created -> "Created"
  | Verifying -> "Verifying"
  | Approved -> "Approved"
  | Rejected _ -> "Rejected"
  | Needs_resubmission _ -> "Needs_resubmission"
  | Blocked _ -> "Blocked"
  | Closed _ -> "Closed"
;;

let transition_name (t : Status.Transition.t) =
  match t with
  | Submit -> "Submit"
  | Approve -> "Approve"
  | Reject _ -> "Reject"
  | Request_resubmission _ -> "Request_resubmission"
  | Block _ -> "Block"
  | Unblock -> "Unblock"
  | Close _ -> "Close"
;;

let state_name (s : Verification.State.t) =
  match s with
  | Pending -> "Pending"
  | Sent -> "Sent"
  | Verified _ -> "Verified"
  | Failed _ -> "Failed"
  | Expired -> "Expired"
;;

let events ~(previous : Customer.Kyc_status.t) ~(current : Customer.Kyc_status.t) ~at =
  let customer = Customer_ref.to_string current.customer in
  let event id update : Event.t =
    { id = Event_id.of_string (sprintf "kyc:%s:%s" customer id)
    ; at
    ; kind = Kyc { customer = current.customer; update }
    }
  in
  let steps =
    List.filter_map current.steps ~f:(fun (step, state) ->
      let before =
        List.Assoc.find previous.steps step ~equal:Verification.Step.equal
        |> Option.value ~default:Verification.State.Pending
      in
      if same_kind before state
      then None
      else
        Some
          (event
             (sprintf
                "step:%s:%s"
                (Sexp.to_string [%sexp (step : Verification.Step.t)])
                (state_name state))
             (Step { step; state })))
  in
  let _, statuses =
    List.fold_map
      (transitions ~from:previous.status ~to_:current.status)
      ~init:previous.status
      ~f:(fun from tr ->
        let next = Status.apply from tr ~actor:(Provider "lightspark") |> Result.ok in
        ( Option.value next ~default:from
        , event (sprintf "%s:%s" (status_name from) (transition_name tr)) (Status tr) ))
  in
  steps @ statuses
;;
