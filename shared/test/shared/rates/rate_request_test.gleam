import birdie
import gleam/json
import shared/rates/rate_request.{RateRequest}

pub fn decode_rate_request_json_test() {
  assert Ok(RateRequest(1, 2781))
    == json.parse("{\"from\":1,\"to\":2781}", rate_request.decoder())
}

pub fn encode_to_json_test() {
  RateRequest(1, 2781)
  |> rate_request.encode
  |> json.to_string
  |> birdie.snap("rate_request_encode_to_json_test")
}
