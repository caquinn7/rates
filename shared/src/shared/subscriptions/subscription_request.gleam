import shared/rates/rate_request.{type RateRequest}

pub type SubscriptionRequest {
  SubscriptionRequest(id: String, rate_request: RateRequest)
}
