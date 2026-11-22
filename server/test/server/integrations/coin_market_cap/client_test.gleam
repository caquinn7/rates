import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import server/integrations/coin_market_cap/client.{
  type CmcResponse, CmcApiError, CmcApiSuccess, CmcStatus,
}
import server/integrations/coin_market_cap/cmc_conversion.{
  CmcConversion, QuoteItem,
}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  CmcCryptoCurrency,
}
import server/integrations/coin_market_cap/cmc_fiat_currency.{CmcFiatCurrency}
import shared/numbers/positive_float

const success_status = "{\"error_code\":0,\"error_message\":null}"

const error_status = "{\"error_code\":400,\"error_message\":\"Invalid request\"}"

const successful_status = CmcStatus(0, None)

const failed_status = CmcStatus(400, Some("Invalid request"))

pub fn crypto_success_requires_data_test() {
  assert_success_requires_data(
    client.cmc_response_decoder(decode.list(cmc_crypto_currency.decoder())),
  )
}

pub fn fiat_success_requires_data_test() {
  assert_success_requires_data(
    client.cmc_response_decoder(decode.list(cmc_fiat_currency.decoder())),
  )
}

pub fn conversion_success_requires_data_test() {
  assert_success_requires_data(
    client.cmc_response_decoder(cmc_conversion.decoder()),
  )
}

pub fn crypto_envelopes_preserve_valid_data_test() {
  let data =
    "[{\"id\":1,\"rank\":null,\"name\":\"Bitcoin\",\"symbol\":\"BTC\"}]"

  assert_envelopes_preserve_data(
    client.cmc_response_decoder(decode.list(cmc_crypto_currency.decoder())),
    data,
    [CmcCryptoCurrency(1, None, "Bitcoin", "BTC")],
  )
}

pub fn fiat_envelopes_preserve_valid_data_test() {
  let data =
    "[{\"id\":2781,\"name\":\"United States Dollar\",\"sign\":\"$\",\"symbol\":\"USD\"}]"

  assert_envelopes_preserve_data(
    client.cmc_response_decoder(decode.list(cmc_fiat_currency.decoder())),
    data,
    [CmcFiatCurrency(2781, "United States Dollar", "$", "USD")],
  )
}

pub fn conversion_envelopes_preserve_valid_data_and_null_prices_test() {
  let data =
    "{\"id\":1,\"symbol\":\"BTC\",\"name\":\"Bitcoin\",\"amount\":1,\"quote\":{\"2781\":{\"price\":null,\"last_updated\":\"2024-09-27T20:57:00.000Z\"}}}"

  assert_envelopes_preserve_data(
    client.cmc_response_decoder(cmc_conversion.decoder()),
    data,
    CmcConversion(
      1,
      "BTC",
      "Bitcoin",
      positive_float.from_float_unsafe(1.0),
      dict.from_list([#("2781", QuoteItem(None, 1_727_470_620_000))]),
    ),
  )
}

pub fn successful_listings_allow_empty_lists_test() {
  let payload = envelope(success_status, "[]")

  assert json.parse(
      payload,
      client.cmc_response_decoder(decode.list(cmc_crypto_currency.decoder())),
    )
    == Ok(CmcApiSuccess(successful_status, []))

  assert json.parse(
      payload,
      client.cmc_response_decoder(decode.list(cmc_fiat_currency.decoder())),
    )
    == Ok(CmcApiSuccess(successful_status, []))
}

pub fn provider_errors_allow_missing_or_null_data_test() {
  assert_provider_error_without_data(
    client.cmc_response_decoder(decode.list(cmc_crypto_currency.decoder())),
  )
  assert_provider_error_without_data(
    client.cmc_response_decoder(decode.list(cmc_fiat_currency.decoder())),
  )
  assert_provider_error_without_data(
    client.cmc_response_decoder(cmc_conversion.decoder()),
  )
}

pub fn malformed_crypto_data_preserves_its_error_path_test() {
  assert_malformed_data_rejected(
    client.cmc_response_decoder(decode.list(cmc_crypto_currency.decoder())),
    "[{\"id\":1,\"name\":\"Bitcoin\",\"symbol\":123}]",
    ["data", "0", "symbol"],
  )
}

pub fn malformed_fiat_data_preserves_its_error_path_test() {
  assert_malformed_data_rejected(
    client.cmc_response_decoder(decode.list(cmc_fiat_currency.decoder())),
    "[{\"id\":2781,\"name\":\"United States Dollar\",\"sign\":123,\"symbol\":\"USD\"}]",
    ["data", "0", "sign"],
  )
}

pub fn malformed_conversion_data_preserves_its_error_path_test() {
  assert_malformed_data_rejected(
    client.cmc_response_decoder(cmc_conversion.decoder()),
    "{\"id\":1,\"symbol\":\"BTC\",\"name\":\"Bitcoin\",\"amount\":1,\"quote\":{\"2781\":{\"price\":null,\"last_updated\":\"invalid\"}}}",
    ["data", "quote", "2781", "last_updated"],
  )
}

fn assert_success_requires_data(decoder: Decoder(a)) {
  ["", ",\"data\":null"]
  |> list.each(fn(data_field) {
    let payload = "{\"status\":" <> success_status <> data_field <> "}"
    let assert Error(json.UnableToDecode([error, ..])) =
      json.parse(payload, decoder)
    let assert ["data", ..] = error.path
  })
}

fn assert_envelopes_preserve_data(
  decoder: Decoder(CmcResponse(a)),
  data: String,
  expected: a,
) {
  assert json.parse(envelope(success_status, data), decoder)
    == Ok(CmcApiSuccess(successful_status, expected))
  assert json.parse(envelope(error_status, data), decoder)
    == Ok(CmcApiError(failed_status, Some(expected)))
}

fn assert_provider_error_without_data(decoder: Decoder(CmcResponse(a))) {
  ["", ",\"data\":null"]
  |> list.each(fn(data_field) {
    let payload = "{\"status\":" <> error_status <> data_field <> "}"
    assert json.parse(payload, decoder) == Ok(CmcApiError(failed_status, None))
  })
}

fn assert_malformed_data_rejected(
  decoder: Decoder(a),
  data: String,
  expected_path: List(String),
) {
  [success_status, error_status]
  |> list.each(fn(status) {
    let assert Error(json.UnableToDecode([error, ..])) =
      json.parse(envelope(status, data), decoder)
    assert error.path == expected_path
  })
}

fn envelope(status: String, data: String) -> String {
  "{\"status\":" <> status <> ",\"data\":" <> data <> "}"
}
