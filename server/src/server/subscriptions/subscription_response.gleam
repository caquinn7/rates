import gleam/json.{type Json}
import server/rates/rate_response
import shared/subscriptions/subscription_id
import shared/subscriptions/subscription_response.{
  type SubscriptionResponse, SubscriptionResponse,
}

pub fn encode(subscription_response: SubscriptionResponse) -> Json {
  let SubscriptionResponse(id, rate_response) = subscription_response

  json.object([
    #("id", json.string(subscription_id.to_string(id))),
    #("rate_response", rate_response.encode(rate_response)),
  ])
}
