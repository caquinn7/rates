import gleam/json
import server/subscriptions/subscription_request
import shared/rates/rate_request.{RateRequest}
import shared/subscriptions/subscription_id
import shared/subscriptions/subscription_request.{SubscriptionRequest} as _shared_sub_request

pub fn decode_subscription_request_json_test() {
  let json = "{\"id\": \"1\", \"rate_request\": { \"from\": 2, \"to\": 3 }}"

  let result = json.parse(json, subscription_request.decoder())

  let assert Ok(SubscriptionRequest(id, RateRequest(2, 3))) = result
  assert "1" == subscription_id.to_string(id)
}
