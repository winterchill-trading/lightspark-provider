open! Core
open! Async
module Lc = Lightspark_client
module J = Yojson.Safe.Util

type t =
  { config : Lc.Config.t
  ; transport : Lc.Transport.t
  ; policy : Lc.Transport.Retry.policy
  ; log : Sexp.t -> unit
  ; grid : Lc.Grid.t
  }

let create
  ?(transport = Lc.Transport.cohttp ())
  ?(policy = Lc.Transport.Retry.default)
  ?(log = fun sexp -> Log.Global.debug_s sexp)
  config
  =
  { config; transport; policy; log; grid = Lc.Grid.create ~transport ~policy ~log config }
;;

let config t = t.config
let grid t = t.grid

(* {2 JSON helpers} *)

let member name json =
  match json with
  | `Assoc _ -> J.member name json
  | _ -> `Null
;;

let str_opt name json =
  match member name json with
  | `String s -> Some s
  | _ -> None
;;

let str name json = Option.value (str_opt name json) ~default:""

let int_opt name json =
  match member name json with
  | `Int i -> Some i
  | `Intlit s -> Int.of_string_opt s
  | `Float f when Float.is_integer f -> Some (Float.to_int f)
  | _ -> None
;;

let float_opt name json =
  match member name json with
  | `Float f -> Some f
  | `Int i -> Some (Float.of_int i)
  | `Intlit s -> Float.of_string_opt s
  | _ -> None
;;

let list name json =
  match member name json with
  | `List l -> l
  | _ -> []
;;

let strings name json = List.filter_map (list name json) ~f:J.to_string_option

let obj_opt name json =
  match member name json with
  | `Assoc _ as o -> Some o
  | _ -> None
;;

(* {2 Views} *)

module Amount = struct
  type t =
    { minor : int
    ; code : string
    ; decimals : int
    }
  [@@deriving sexp, compare, equal]

  let of_json json =
    let currency = member "currency" json in
    { minor = Option.value (int_opt "amount" json) ~default:0
    ; code = str "code" currency
    ; decimals = Option.value (int_opt "decimals" currency) ~default:2
    }
  ;;

  let to_money t = Units.amount ~code:t.code ~decimals:t.decimals t.minor
end

let amount_opt name json = Option.map (obj_opt name json) ~f:Amount.of_json

module Funding_instruction = struct
  type t =
    { account_type : string
    ; address : string option
    ; asset_type : string option
    ; account_number : string option
    ; routing_number : string option
    ; iban : string option
    ; swift_code : string option
    ; bank_name : string option
    ; reference : string option
    ; payment_rails : string list
    }
  [@@deriving sexp, compare, equal]

  let of_json json =
    let info = member "accountOrWalletInfo" json in
    { account_type = str "accountType" info
    ; address = str_opt "address" info
    ; asset_type = str_opt "assetType" info
    ; account_number = str_opt "accountNumber" info
    ; routing_number = str_opt "routingNumber" info
    ; iban = str_opt "iban" info
    ; swift_code = str_opt "swiftCode" info
    ; bank_name = str_opt "bankName" info
    ; reference = str_opt "reference" info
    ; payment_rails = strings "paymentRails" info
    }
  ;;
end

module Internal_account = struct
  type t =
    { id : string
    ; customer_id : string option
    ; type_ : string
    ; status : string
    ; balance : Amount.t
    ; total_balance : Amount.t option
    ; funding : Funding_instruction.t list
    ; created_at : string
    }
  [@@deriving sexp, compare, equal]

  let of_json json =
    { id = str "id" json
    ; customer_id = str_opt "customerId" json
    ; type_ = str "type" json
    ; status = str "status" json
    ; balance = Amount.of_json (member "balance" json)
    ; total_balance = amount_opt "totalBalance" json
    ; funding =
        List.map (list "fundingPaymentInstructions" json) ~f:Funding_instruction.of_json
    ; created_at = str "createdAt" json
    }
  ;;
end

module Customer = struct
  type t =
    { id : string
    ; platform_customer_id : string option
    ; kyc_status : string option
    ; email_verification : string option
    ; phone_verification : string option
    ; created_at : string
    }
  [@@deriving sexp, compare, equal]

  let of_json json =
    let contact = member "contactVerification" json in
    { id = str "id" json
    ; platform_customer_id = str_opt "platformCustomerId" json
    ; kyc_status = str_opt "kycStatus" json
    ; email_verification = str_opt "email" contact
    ; phone_verification = str_opt "phone" contact
    ; created_at = str "createdAt" json
    }
  ;;
end

module External_account = struct
  type t =
    { id : string
    ; customer_id : string option
    ; status : string
    ; currency : string
    ; platform_account_id : string option
    ; account_type : string option
    ; beneficiary_verification : string option
    }
  [@@deriving sexp, compare, equal]

  let of_json json =
    { id = str "id" json
    ; customer_id = str_opt "customerId" json
    ; status = str "status" json
    ; currency = str "currency" json
    ; platform_account_id = str_opt "platformAccountId" json
    ; account_type = str_opt "accountType" (member "accountInfo" json)
    ; beneficiary_verification = str_opt "beneficiaryVerificationStatus" json
    }
  ;;
end

module Sca_challenge = struct
  type t =
    { id : string
    ; expires_at : string
    ; factor : string
    ; available_factors : string list
    ; purpose : string option
    }
  [@@deriving sexp, compare, equal]

  let of_json json =
    { id = str "id" json
    ; expires_at = str "expiresAt" json
    ; factor = str "factor" json
    ; available_factors = strings "availableFactors" json
    ; purpose = str_opt "purpose" json
    }
  ;;
end

module Quote = struct
  type t =
    { id : string
    ; status : string
    ; created_at : string
    ; expires_at : string
    ; sending_code : string
    ; sending_decimals : int
    ; receiving_code : string
    ; receiving_decimals : int
    ; total_sending : int
    ; total_receiving : int
    ; exchange_rate : float
    ; fees_included : int
    ; transaction_id : string option
    ; sca_challenge : Sca_challenge.t option
    }
  [@@deriving sexp, compare, equal]

  let of_json json =
    let sending = member "sendingCurrency" json in
    let receiving = member "receivingCurrency" json in
    { id = str "id" json
    ; status = str "status" json
    ; created_at = str "createdAt" json
    ; expires_at = str "expiresAt" json
    ; sending_code = str "code" sending
    ; sending_decimals = Option.value (int_opt "decimals" sending) ~default:2
    ; receiving_code = str "code" receiving
    ; receiving_decimals = Option.value (int_opt "decimals" receiving) ~default:2
    ; total_sending = Option.value (int_opt "totalSendingAmount" json) ~default:0
    ; total_receiving = Option.value (int_opt "totalReceivingAmount" json) ~default:0
    ; exchange_rate = Option.value (float_opt "exchangeRate" json) ~default:0.
    ; fees_included = Option.value (int_opt "feesIncluded" json) ~default:0
    ; transaction_id = str_opt "transactionId" json
    ; sca_challenge = Option.map (obj_opt "scaChallenge" json) ~f:Sca_challenge.of_json
    }
  ;;
end

module Transaction = struct
  type t =
    { id : string
    ; status : string
    ; type_ : string
    ; direction : string option
    ; customer_id : string option
    ; description : string option
    ; sent : Amount.t option
    ; received : Amount.t option
    ; fees : int option
    ; quote_id : string option
    ; failure_reason : string option
    ; payment_rail : string option
    ; source_type : string option
    ; source_account_id : string option
    ; destination_type : string option
    ; destination_account_id : string option
    ; tx_hash : string option
    ; network : string option
    ; created_at : string option
    ; updated_at : string option
    ; settled_at : string option
    }
  [@@deriving sexp, compare, equal]

  let of_json json =
    let source = member "source" json in
    let destination = member "destination" json in
    let rail_details side =
      match member "railDetails" side with
      | `Assoc _ as r -> Some r
      | _ -> obj_opt "onChainTransaction" side
    in
    let on_chain =
      List.find_map [ destination; source ] ~f:(fun side ->
        Option.bind (rail_details side) ~f:(fun r ->
          Option.map (str_opt "transactionHash" r) ~f:(fun h -> h, str_opt "network" r)))
    in
    { id = str "id" json
    ; status = str "status" json
    ; type_ = str "type" json
    ; direction = str_opt "direction" json
    ; customer_id = str_opt "customerId" json
    ; description = str_opt "description" json
    ; sent = amount_opt "sentAmount" json
    ; received = amount_opt "receivedAmount" json
    ; fees = int_opt "fees" json
    ; quote_id = str_opt "quoteId" json
    ; failure_reason = str_opt "failureReason" json
    ; payment_rail = str_opt "paymentRail" json
    ; source_type = str_opt "sourceType" source
    ; source_account_id = str_opt "accountId" source
    ; destination_type = str_opt "destinationType" destination
    ; destination_account_id = str_opt "accountId" destination
    ; tx_hash = Option.map on_chain ~f:fst
    ; network = Option.bind on_chain ~f:snd
    ; created_at = str_opt "createdAt" json
    ; updated_at = str_opt "updatedAt" json
    ; settled_at = str_opt "settledAt" json
    }
  ;;
end

module Balance_change = struct
  type t =
    { id : string
    ; transaction_id : string option
    ; amount : Amount.t
    ; effective_at : string
    }
  [@@deriving sexp, compare, equal]

  let of_json json =
    { id = str "id" json
    ; transaction_id = str_opt "transactionId" json
    ; amount = Amount.of_json (member "amount" json)
    ; effective_at = str "effectiveAt" json
    }
  ;;
end

module Kyc_link = struct
  type t =
    { url : string
    ; expires_at : string
    ; token : string option
    }

  (* The URL and token open a hosted session for one person: never print them. *)
  let sexp_of_t t = [%sexp { url = "<redacted>"; expires_at = (t.expires_at : string) }]

  let of_json json =
    { url = str "kycUrl" json
    ; expires_at = str "expiresAt" json
    ; token = str_opt "token" json
    }
  ;;
end

module Rate = struct
  type t =
    { source : string
    ; destination : string
    ; destination_decimals : int
    ; rail : string option
    ; exchange_rate : float
    ; fee_total : int option
    ; sending_amount : int option
    ; receiving_amount : int option
    ; min_sending : int option
    ; max_sending : int option
    }
  [@@deriving sexp, compare, equal]

  let of_json json =
    let destination = member "destinationCurrency" json in
    { source = str "code" (member "sourceCurrency" json)
    ; destination = str "code" destination
    ; destination_decimals = Option.value (int_opt "decimals" destination) ~default:2
    ; rail = str_opt "destinationPaymentRail" json
    ; exchange_rate = Option.value (float_opt "exchangeRate" json) ~default:0.
    ; fee_total = int_opt "total" (member "fees" json)
    ; sending_amount = int_opt "sendingAmount" json
    ; receiving_amount = int_opt "receivingAmount" json
    ; min_sending = int_opt "minSendingAmount" json
    ; max_sending = int_opt "maxSendingAmount" json
    }
  ;;
end

(* {2 Requests} *)

let uri t path query =
  let base = (t.config : Lc.Config.t).grid_url in
  let base_path = String.chop_suffix_if_exists (Uri.path base) ~suffix:"/" in
  Uri.with_query' (Uri.with_path base (base_path ^ path)) query
;;

let path_id id = Uri.pct_encode ~component:`Path id

(* The same request shape as lightspark-client's Grid module: Basic auth, JSON, an
   Idempotency-Key on creates, and a resend after a timeout only when the request is
   idempotent. *)
let request ?body ?idempotency_key ?(query = []) t ~meth ~path ~what of_json =
  let idempotent =
    match meth with
    | `GET | `DELETE | `PUT -> true
    | `POST | `PATCH -> Option.is_some idempotency_key
  in
  let headers =
    [ Lc.Auth.header t.config; "Accept", "application/json" ]
    @ Option.value_map body ~default:[] ~f:(fun _ ->
      [ "Content-Type", "application/json" ])
    @ Option.value_map idempotency_key ~default:[] ~f:(fun k -> [ "Idempotency-Key", k ])
  in
  let request =
    { Lc.Transport.Request.meth
    ; uri = uri t path query
    ; headers
    ; body = Option.map body ~f:Yojson.Safe.to_string
    ; idempotent
    }
  in
  match%map Lc.Transport.Retry.run ~policy:t.policy ~log:t.log t.transport request with
  | Error message -> Error (Lc.Api_error.Transport (Lc.Auth.redact t.config message))
  | Ok response ->
    t.log
      [%message
        "grid"
          ~meth:(meth : Lc.Transport.Meth.t)
          (path : string)
          ~status:(response.status : int)
          ~request_id:
            (Option.value (Lc.Transport.Response.request_id response) ~default:"-"
             : string)];
    Lc.Grid.decode_response ~redact:(Lc.Auth.redact t.config) ~what of_json response
;;

let get ?query t ~path ~what of_json = request ?query t ~meth:`GET ~path ~what of_json

let guarded t f =
  match%bind Lc.Grid.ensure_sandbox_or_live t.grid with
  | Error _ as e -> return e
  | Ok () -> f ()
;;

let page_items of_json json = List.map (list "data" json) ~f:of_json

let page_next json =
  match member "hasMore" json, str_opt "nextCursor" json with
  | `Bool true, Some c -> Some c
  | _ -> None
;;

(* Follows [nextCursor] up to [max_pages]. *)
let all_pages ?(max_pages = 50) fetch =
  let rec loop acc cursor n =
    match%bind fetch ~cursor with
    | Error _ as e -> return e
    | Ok (items, next) ->
      let acc = List.rev_append items acc in
      (match next with
       | Some c when n < max_pages -> loop acc (Some c) (n + 1)
       | _ -> return (Ok (List.rev acc)))
  in
  loop [] None 1
;;

let paged t ~path ~what ~query of_json ?max_pages () =
  all_pages ?max_pages (fun ~cursor ->
    get
      t
      ~path
      ~what
      ~query:
        (query
         @ [ "limit", "100" ]
         @ Option.to_list (Option.map cursor ~f:(fun c -> "cursor", c)))
      (fun json -> page_items of_json json, page_next json))
;;

(* {2 Customers} *)

let find_customer t ~platform_customer_id =
  get
    t
    ~path:"/customers"
    ~query:[ "platformCustomerId", platform_customer_id ]
    ~what:"customers"
    (fun json ->
      page_items Customer.of_json json
      |> List.find ~f:(fun (c : Customer.t) ->
        Option.equal String.equal c.platform_customer_id (Some platform_customer_id)))
;;

let customer t ~id =
  get t ~path:("/customers/" ^ path_id id) ~what:"customer" Customer.of_json
;;

module New_customer = struct
  type t =
    { platform_customer_id : string
    ; full_name : string
    ; birth_date : Date.t
    ; nationality : string
    ; email : string
    ; address_line1 : string
    ; address_line2 : string option
    ; city : string
    ; region : string option
    ; postal_code : string
    ; country : string
    }

  (* Personal data: only the shape is ever printed. *)
  let sexp_of_t t = [%sexp { platform_customer_id = (t.platform_customer_id : string) }]

  let address t =
    `Assoc
      (List.filter_opt
         [ Some ("line1", `String t.address_line1)
         ; Option.map t.address_line2 ~f:(fun l -> "line2", `String l)
         ; Some ("city", `String t.city)
         ; Option.map t.region ~f:(fun r -> "state", `String r)
         ; Some ("postalCode", `String t.postal_code)
         ; Some ("country", `String t.country)
         ])
  ;;

  let personal t =
    [ "fullName", `String t.full_name
    ; "birthDate", `String (Date.to_string t.birth_date)
    ; "nationality", `String t.nationality
    ; "address", address t
    ]
  ;;

  let to_json t =
    `Assoc
      ([ "customerType", `String "INDIVIDUAL"
       ; "platformCustomerId", `String t.platform_customer_id
       ; "email", `String t.email
       ]
       @ personal t)
  ;;
end

let create_customer t (c : New_customer.t) ~idempotency_key =
  guarded t (fun () ->
    request
      t
      ~meth:`POST
      ~path:"/customers"
      ~body:(New_customer.to_json c)
      ~idempotency_key
      ~what:"customer"
      Customer.of_json)
;;

let update_customer t ~id c =
  request
    t
    ~meth:`PATCH
    ~path:("/customers/" ^ path_id id)
    ~body:(`Assoc (("customerType", `String "INDIVIDUAL") :: New_customer.personal c))
    ~what:"customer update"
    (fun _ -> ())
;;

let channel = function
  | `Email -> "verify-email"
  | `Phone -> "verify-phone"
;;

let start_contact_verification t ~id which =
  request
    t
    ~meth:`POST
    ~path:(sprintf "/customers/%s/%s" (path_id id) (channel which))
    ~what:"contact verification"
    (fun _ -> ())
;;

let confirm_contact_verification t ~id which ~code =
  request
    t
    ~meth:`POST
    ~path:(sprintf "/customers/%s/%s/confirm" (path_id id) (channel which))
    ~body:(`Assoc [ "code", `String code ])
    ~what:"contact verification"
    (fun json ->
      (* The answer is the customer, or the verification state alone. *)
      match str_opt "id" json with
      | Some _ -> Customer.of_json json
      | None ->
        { Customer.id
        ; platform_customer_id = None
        ; kyc_status = None
        ; email_verification = str_opt "email" json
        ; phone_verification = str_opt "phone" json
        ; created_at = ""
        })
;;

let kyc_link t ~id =
  request
    t
    ~meth:`POST
    ~path:(sprintf "/customers/%s/kyc-link" (path_id id))
    ~body:(`Assoc [])
    ~what:"kyc link"
    Kyc_link.of_json
;;

(* {2 Accounts} *)

let customer_accounts t ~customer_id =
  paged
    t
    ~path:"/customers/internal-accounts"
    ~what:"internal accounts"
    ~query:[ "customerId", customer_id ]
    Internal_account.of_json
    ()
;;

let iso time = Time_ns.to_string_iso8601_basic time ~zone:Time_float.Zone.utc

let balance_changes t ~account_id ~start ~stop =
  paged
    t
    ~path:(sprintf "/internal-accounts/%s/balance-changes" (path_id account_id))
    ~what:"balance changes"
    ~query:[ "startDate", iso start; "endDate", iso stop ]
    Balance_change.of_json
    ()
;;

let sandbox_fund t ~account_id ~amount ~description =
  request
    t
    ~meth:`POST
    ~path:(sprintf "/sandbox/internal-accounts/%s/fund" (path_id account_id))
    ~body:(`Assoc [ "amount", `Int amount; "description", `String description ])
    ~what:"sandbox fund"
    Internal_account.of_json
;;

(* {2 External accounts} *)

let external_accounts t ~customer_id =
  paged
    t
    ~path:"/customers/external-accounts"
    ~what:"external accounts"
    ~query:[ "customerId", customer_id ]
    External_account.of_json
    ()
;;

let create_external_account
  t
  ~customer_id
  ~currency
  ~platform_account_id
  ~account_info
  ~idempotency_key
  =
  guarded t (fun () ->
    request
      t
      ~meth:`POST
      ~path:"/customers/external-accounts"
      ~body:
        (`Assoc
          [ "customerId", `String customer_id
          ; "currency", `String currency
          ; "platformAccountId", `String platform_account_id
          ; "accountInfo", account_info
          ])
      ~idempotency_key
      ~what:"external account"
      External_account.of_json)
;;

(* {2 Quotes and transactions} *)

module Destination = struct
  type t =
    | Account of
        { account_id : string
        ; payment_rail : string option
        }

  let to_json = function
    | Account { account_id; payment_rail } ->
      `Assoc
        (List.filter_opt
           [ Some ("destinationType", `String "ACCOUNT")
           ; Some ("accountId", `String account_id)
           ; Option.map payment_rail ~f:(fun r -> "paymentRail", `String r)
           ])
  ;;
end

let create_quote
  ?description
  ?remittance
  ?(sender_info = [])
  ?(immediately_execute = false)
  t
  ~source_account_id
  ~destination
  ~locked
  ~amount
  ~idempotency_key
  =
  guarded t (fun () ->
    let body =
      `Assoc
        (List.filter_opt
           [ Some
               ( "source"
               , `Assoc
                   [ "sourceType", `String "ACCOUNT"
                   ; "accountId", `String source_account_id
                   ] )
           ; Some ("destination", Destination.to_json destination)
           ; Some
               ( "lockedCurrencySide"
               , `String
                   (match locked with
                    | `Sending -> "SENDING"
                    | `Receiving -> "RECEIVING") )
           ; Some ("lockedCurrencyAmount", `Int amount)
           ; Some ("immediatelyExecute", `Bool immediately_execute)
           ; Option.map description ~f:(fun d -> "description", `String d)
           ; Option.map remittance ~f:(fun r -> "remittanceInformation", `String r)
           ; (if List.is_empty sender_info
              then None
              else
                Some
                  ( "senderCustomerInfo"
                  , `Assoc (List.map sender_info ~f:(fun (k, v) -> k, `String v)) ))
           ])
    in
    request
      t
      ~meth:`POST
      ~path:"/quotes"
      ~body
      ~idempotency_key
      ~what:"quote"
      Quote.of_json)
;;

let quote t ~id = get t ~path:("/quotes/" ^ path_id id) ~what:"quote" Quote.of_json

let execute_quote t ~id ~idempotency_key =
  guarded t (fun () ->
    request
      t
      ~meth:`POST
      ~path:(sprintf "/quotes/%s/execute" (path_id id))
      ~idempotency_key
      ~what:"quote execution"
      Quote.of_json)
;;

let authorize_quote ?end_user_ip t ~id ~code =
  request
    t
    ~meth:`POST
    ~path:(sprintf "/quotes/%s/authorize" (path_id id))
    ~body:
      (`Assoc
        (("code", `String code)
         :: Option.to_list
              (Option.map end_user_ip ~f:(fun ip -> "endUserIpAddress", `String ip))))
    ~what:"quote authorization"
    Quote.of_json
;;

let transaction t ~id =
  get t ~path:("/transactions/" ^ path_id id) ~what:"transaction" Transaction.of_json
;;

let transactions ?(max_pages = 3) t ~customer_id =
  paged
    t
    ~path:"/transactions"
    ~what:"transactions"
    ~query:[ "customerId", customer_id ]
    Transaction.of_json
    ~max_pages
    ()
;;

let cancel_transaction t ~id =
  request
    t
    ~meth:`POST
    ~path:(sprintf "/transactions/%s/cancel" (path_id id))
    ~body:(`Assoc [])
    ~what:"transaction cancel"
    Transaction.of_json
;;

(* {2 Rates and webhooks} *)

let rates ?sending_amount t ~source ~destination =
  get
    t
    ~path:"/exchange-rates"
    ~query:
      ([ "sourceCurrency", source; "destinationCurrency", destination ]
       @ Option.to_list
           (Option.map sending_amount ~f:(fun a -> "sendingAmount", Int.to_string a)))
    ~what:"exchange rates"
    (page_items Rate.of_json)
;;

let send_test_webhook t =
  request t ~meth:`POST ~path:"/webhooks/test" ~what:"test webhook" (fun json ->
    Option.value (int_opt "response_status" json) ~default:0)
;;
