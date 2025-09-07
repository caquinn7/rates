import shared/rates/rate_response.{type RateResponse}
import shared/subscriptions/subscription_id.{type SubscriptionId}

pub type SubscriptionResponse {
  SubscriptionResponse(id: SubscriptionId, rate_response: RateResponse)
}
