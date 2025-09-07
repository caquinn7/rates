import gleam/dynamic/decode.{type Decoder}
import server/rates/rate_request
import shared/subscriptions/subscription_request.{
  type SubscriptionRequest, SubscriptionRequest,
}

pub fn decoder() -> Decoder(SubscriptionRequest) {
  use id <- decode.field("id", decode.string)
  use rate_request <- decode.field("rate_request", rate_request.decoder())
  decode.success(SubscriptionRequest(id:, rate_request:))
}
