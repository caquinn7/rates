import shared/rates/rate_response.{type RateResponse}

pub type SubscriptionResponse {
  SubscriptionResponse(id: String, rate_response: RateResponse)
}
