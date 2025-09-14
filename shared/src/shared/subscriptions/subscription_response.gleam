import gleam/json.{type Json}
import shared/rates/rate_response.{type RateResponse}
import shared/subscriptions/subscription_id.{type SubscriptionId}

pub type SubscriptionResponse {
  SubscriptionResponse(id: SubscriptionId, rate_response: RateResponse)
}

pub fn encode(subscription_response: SubscriptionResponse) -> Json {
  let SubscriptionResponse(id, rate_response) = subscription_response

  json.object([
    #("id", subscription_id.encode(id)),
    #("rate_response", rate_response.encode(rate_response)),
  ])
}
