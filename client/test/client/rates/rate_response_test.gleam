import client/rates/rate_response
import gleam/json
import shared/rates/rate_response.{Kraken, RateResponse} as _shared_rate_response

pub fn decode_rate_response_json_test() {
  let result =
    "{\"from\":1,\"to\":2781,\"rate\":100000.0,\"source\":\"Kraken\",\"timestamp\":1756654456}"
    |> json.parse(rate_response.decoder())

  assert Ok(RateResponse(1, 2781, 100_000.0, Kraken, 1_756_654_456)) == result
}
