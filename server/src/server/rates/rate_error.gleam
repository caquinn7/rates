import server/rates/internal/cmc_rate_handler.{type RateRequestError}
import shared/rates/rate_request.{type RateRequest}

/// Failures encountered when looking up a quote for a rate subscription.
pub type RateError {
  /// A source or target currency was not found in the currency repository.
  /// Carries the original request and the missing currency ID.
  CurrencyNotFound(RateRequest, Int)

  /// A CoinMarketCap conversion failed. Carries the original request and the
  /// underlying validation, request, or response error.
  CmcError(RateRequest, RateRequestError)
}
