import birdie
import gleam/json
import server/rates/rate_response
import shared/rates/rate_response.{Kraken, RateResponse} as _shared_rate_response

pub fn rate_response_encode_to_json_test() {
  RateResponse(1, 2781, 100_000.0, Kraken)
  |> rate_response.encode
  |> json.to_string
  |> birdie.snap("rate_response_encode_to_json_test")
}
