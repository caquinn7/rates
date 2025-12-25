import gleam/json
import gleam/option.{None, Some}
import shared/rates/rate_response.{Kraken, RateResponse}

pub fn decode_rate_response_json_test() {
  let result =
    "{\"from\":1,\"to\":2781,\"rate\":100000.0,\"source\":\"Kraken\",\"timestamp\":1756654456}"
    |> json.parse(rate_response.decoder())

  assert Ok(RateResponse(1, 2781, Some(100_000.0), Kraken, 1_756_654_456))
    == result
}

pub fn decode_rate_response_with_null_rate_test() {
  let result =
    "{\"from\":1,\"to\":2781,\"rate\":null,\"source\":\"Kraken\",\"timestamp\":1756654456}"
    |> json.parse(rate_response.decoder())

  assert Ok(RateResponse(1, 2781, None, Kraken, 1_756_654_456)) == result
}

pub fn encode_rate_response_to_json_test() {
  let rate_response =
    RateResponse(1, 2781, Some(100_000.0), Kraken, 1_756_654_456)

  let result =
    rate_response
    |> rate_response.encode
    |> json.to_string
    |> json.parse(rate_response.decoder())

  assert result == Ok(rate_response)
}

pub fn encode_rate_response_when_rate_is_none_test() {
  let rate_response = RateResponse(1, 2781, None, Kraken, 1_756_654_456)

  let result =
    rate_response
    |> rate_response.encode
    |> json.to_string
    |> json.parse(rate_response.decoder())

  assert result == Ok(rate_response)
}
