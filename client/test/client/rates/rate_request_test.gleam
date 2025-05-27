import birdie
import client/rates/rate_request
import gleam/json
import shared/rates/rate_request.{RateRequest} as _shared_rate_request

pub fn rate_request_encode_to_json_test() {
  RateRequest(1, 2781)
  |> rate_request.encode
  |> json.to_string
  |> birdie.snap("rate_request_encode_to_json_test")
}
