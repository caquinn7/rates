import shared/rates/rate_request.{type RateRequest}
import shared/subscriptions/subscription_id.{type SubscriptionId}

pub type SubscriptionRequest {
  SubscriptionRequest(id: SubscriptionId, rate_request: RateRequest)
}
