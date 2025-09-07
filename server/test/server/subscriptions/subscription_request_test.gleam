import gleam/json
import server/subscriptions/subscription_request
import shared/rates/rate_request.{RateRequest}
import shared/subscriptions/subscription_request.{SubscriptionRequest} as _shared_sub_request

pub fn decode_subscription_request_json_test() {
  assert Ok(SubscriptionRequest("1", RateRequest(2, 3)))
    == json.parse(
      "{\"id\": \"1\", \"rate_request\": { \"from\": 2, \"to\": 3 }}",
      subscription_request.decoder(),
    )
}
