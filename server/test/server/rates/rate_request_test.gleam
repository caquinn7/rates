import gleam/json
import server/rates/rate_request
import shared/rates/rate_request.{RateRequest} as _shared_rate_request

pub fn decode_rate_request_json_test() {
  assert Ok(RateRequest(1, 2781))
    == json.parse("{\"from\":1,\"to\":2781}", rate_request.decoder())
}
