import server/rates/internal/cmc_rate_handler.{type RateRequestError}
import shared/rates/rate_request.{type RateRequest}

pub type RateError {
  CurrencyNotFound(RateRequest, Int)
  CmcError(RateRequest, RateRequestError)
  /// The one-shot resolver did not finish within its caller-supplied deadline.
  TimedOut(RateRequest)
}
