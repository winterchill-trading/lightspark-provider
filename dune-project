(lang dune 3.17)

(name lightspark-provider)

(generate_opam_files true)

(license MIT)

(maintainers "hello@winterchill.xyz")

(authors "WinterChill AI")

(source
 (github winterchill-trading/lightspark-provider))

(homepage "https://github.com/winterchill-trading/lightspark-provider")

(bug_reports "https://github.com/winterchill-trading/lightspark-provider/issues")

(documentation "https://github.com/winterchill-trading/lightspark-provider#readme")

(package
 (name lightspark-provider)
 (synopsis "banking-provider's Provider.S implemented over the Lightspark Grid API")
 (description
  "Adapter from the provider-neutral banking-provider interface to lightspark-client's Grid API: customers, USD and stablecoin accounts, cross-border payouts to bank accounts and wallets with FX quotes, conversions between a customer's own accounts, sandbox funding and webhooks normalized into banking-provider events. Sandbox by default.")
 (tags
  (banking payments fx async))
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  async_kernel
  ppx_jane
  ppx_yojson_conv
  yojson
  uri
  zarith
  money
  ledger
  kyc-core
  payments-core
  card-core
  banking-provider
  lightspark-client
  (expect_test_helpers_core :with-test)))
