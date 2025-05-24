import gleam/json
import gleeunit/should
import server/rates/rate_request
import shared/rates/rate_request.{RateRequest} as _shared_rate_request

pub fn decode_rate_request_json_test() {
  "{\"from\":1,\"to\":2781}"
  |> json.parse(rate_request.decoder())
  |> should.be_ok
  |> should.equal(RateRequest(1, 2781))
}
