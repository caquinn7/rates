import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/rates/rate_request.{type RateRequest}
import shared/subscriptions/subscription_id.{type SubscriptionId}

pub type SubscriptionRequest {
  SubscriptionRequest(id: SubscriptionId, rate_request: RateRequest)
}

pub fn encode(subscription_request: SubscriptionRequest) -> Json {
  let SubscriptionRequest(id:, rate_request:) = subscription_request
  json.object([
    #("id", subscription_id.encode(id)),
    #("rate_request", rate_request.encode(rate_request)),
  ])
}

pub fn decoder() -> Decoder(SubscriptionRequest) {
  use id <- decode.field("id", subscription_id.decoder())
  use rate_request <- decode.field("rate_request", rate_request.decoder())
  decode.success(SubscriptionRequest(id:, rate_request:))
}
