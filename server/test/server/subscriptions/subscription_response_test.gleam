import birdie
import gleam/json
import server/subscriptions/subscription_response
import shared/rates/rate_response.{Kraken, RateResponse} as _shared_rate_response
import shared/subscriptions/subscription_response.{SubscriptionResponse} as _shared_sub_response

pub fn subscription_response_encode_to_json_test() {
  SubscriptionResponse("1", RateResponse(2, 3, 1.23, Kraken, 1_756_654_456))
  |> subscription_response.encode
  |> json.to_string
  |> birdie.snap("subscription_response_encode_to_json_test")
}
