import birdie
import gleam/json
import gleam/option.{None, Some}
import shared/currency.{Crypto, Fiat}

pub fn decoder_decodes_crypto_test() {
  let result =
    "{\"type\":\"crypto\",\"id\":1,\"name\":\"Bitcoin\",\"symbol\":\"BTC\",\"rank\":1}"
    |> json.parse(currency.decoder())

  assert Ok(Crypto(1, "Bitcoin", "BTC", Some(1))) == result
}

pub fn decoder_decodes_crypto_with_no_rank_test() {
  let result =
    "{\"type\":\"crypto\",\"id\":1,\"name\":\"Bitcoin\",\"symbol\":\"BTC\",\"rank\":null}"
    |> json.parse(currency.decoder())

  assert Ok(Crypto(1, "Bitcoin", "BTC", None)) == result
}

pub fn decoder_decodes_fiat_test() {
  let result =
    "{\"type\":\"fiat\",\"id\":2781,\"name\":\"United States Dollar\",\"symbol\":\"USD\",\"sign\":\"$\"}"
    |> json.parse(currency.decoder())

  assert Ok(Fiat(2781, "United States Dollar", "USD", "$")) == result
}

pub fn decoder_returns_error_when_input_is_invalid_test() {
  let result = json.parse("", currency.decoder())
  let assert Error(_) = result
}

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
