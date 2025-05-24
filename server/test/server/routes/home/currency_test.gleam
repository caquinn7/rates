import birdie
import gleam/json
import gleam/option.{None, Some}
import server/routes/home/currency
import shared/currency.{Crypto, Fiat} as _shared_currency

pub fn encode_crypto_currency_to_json_test() {
  Crypto(1, "Bitcoin", "BTC", Some(1))
  |> currency.encode
  |> json.to_string
  |> birdie.snap("encode_crypto_currency_to_json_test")
}

pub fn encode_crypto_currency_with_no_rank_to_json_test() {
  Crypto(1, "Bitcoin", "BTC", None)
  |> currency.encode
  |> json.to_string
  |> birdie.snap("encode_crypto_currency_with_no_rank_to_json_test")
}

pub fn encode_fiat_currency_to_json_test() {
  Fiat(2781, "United States Dollar", "USD", "$")
  |> currency.encode
  |> json.to_string
  |> birdie.snap("encode_fiat_currency_to_json_test")
}
