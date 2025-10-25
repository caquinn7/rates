import birdie
import gleam/json
import shared/rates/rate_request.{RateRequest}
import shared/subscriptions/subscription_id
import shared/subscriptions/subscription_request.{SubscriptionRequest}

pub fn decode_subscription_request_json_test() {
  let json = "{\"id\": \"1\", \"rate_request\": { \"from\": 2, \"to\": 3 }}"

  let result = json.parse(json, subscription_request.decoder())

  let assert Ok(SubscriptionRequest(id, RateRequest(2, 3))) = result
  assert "1" == subscription_id.to_string(id)
}

pub fn encode_subscription_request_to_json_test() {
  let assert Ok(sub_id) = subscription_id.new("1")

  sub_id
  |> SubscriptionRequest(RateRequest(2, 3))
  |> subscription_request.encode
  |> json.to_string
  |> birdie.snap("encode_subscription_request_to_json_test")
}
