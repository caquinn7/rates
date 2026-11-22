import gleam/option.{Some}
import gleam/result
import server/integrations/kraken/price_store.{type PriceEntry}
import server/rates/internal/cmc_rate_handler.{type RequestCmcConversion}
import server/rates/internal/kraken_symbol.{type KrakenSymbol}
import server/rates/rate_error.{type RateError, CmcError, CurrencyNotFound}
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse, RateResponse}

/// The lookup strategy selected for a currency pair.
pub type RateSourceStrategy {
  /// Tries Kraken, falling back to CoinMarketCap if no usable price is available.
  /// Carries the resolved Kraken pair and its price direction.
  KrakenStrategy(KrakenSymbol)

  /// Requests a CoinMarketCap conversion directly.
  /// Selected when no supported Kraken pair can be resolved.
  CmcStrategy
}

/// Why the rate strategy falls back from Kraken to CoinMarketCap.
pub type KrakenFallbackReason {
  /// The Kraken price lookup found no quote for the resolved pair.
  PriceUnavailable

  /// The reciprocal required for the reversed pair is outside the range of
  /// positive, finite floats.
  ReciprocalOutOfRange
}

pub type StrategyConfig {
  StrategyConfig(
    /// Looks up the stored price and provider timestamp for a Kraken pair.
    /// The strategy applies any inversion needed for the requested direction.
    /// An unavailable quote triggers CMC fallback.
    check_for_kraken_price: fn(KrakenSymbol) -> Result(PriceEntry, Nil),
    /// Requests a CoinMarketCap conversion for the supplied amount and currency IDs.
    /// Returns the decoded provider response or an HTTP/JSON decoding error.
    request_cmc_conversion: RequestCmcConversion,
    /// Reports why the Kraken price could not be used before requesting CMC.
    on_kraken_fallback: fn(KrakenFallbackReason) -> Nil,
  )
}

/// Validates the requested currency IDs and selects a lookup strategy.
/// Uses Kraken when `create_kraken_symbol` succeeds, otherwise CoinMarketCap.
///
/// Returns `CurrencyNotFound` with the original request and the first currency ID
/// that `get_currency_by_id` cannot resolve.
pub fn determine_strategy(
  rate_request: RateRequest,
  get_currency_by_id: fn(Int) -> Result(Currency, Nil),
  create_kraken_symbol: fn(#(Int, Int)) -> Result(KrakenSymbol, Nil),
) -> Result(RateSourceStrategy, RateError) {
  let validate_currency = fn(id) {
    id
    |> get_currency_by_id
    |> result.replace_error(CurrencyNotFound(rate_request, id))
  }
  use _ <- result.try(validate_currency(rate_request.from))
  use _ <- result.try(validate_currency(rate_request.to))

  Ok(case create_kraken_symbol(#(rate_request.from, rate_request.to)) {
    Ok(symbol) -> KrakenStrategy(symbol)
    Error(_) -> CmcStrategy
  })
}

/// Fetches a quote using the selected strategy. If the Kraken price is missing
/// or its reciprocal is out of range, calls `on_kraken_fallback` before requesting CMC.
///
/// Returns the rate result and the source to use for the next refresh. A CMC
/// attempt returns `CmcStrategy` even if the request fails.
pub fn execute_strategy(
  strategy: RateSourceStrategy,
  rate_request: RateRequest,
  config: StrategyConfig,
) -> #(Result(RateResponse, RateError), RateSourceStrategy) {
  case strategy {
    KrakenStrategy(symbol) ->
      execute_kraken_strategy(rate_request, symbol, config)

    CmcStrategy -> execute_cmc_strategy(rate_request, config)
  }
}

fn execute_kraken_strategy(
  rate_request: RateRequest,
  kraken_symbol: KrakenSymbol,
  config: StrategyConfig,
) -> #(Result(RateResponse, RateError), RateSourceStrategy) {
  let kraken_response = {
    use price_entry <- result.try(
      kraken_symbol
      |> config.check_for_kraken_price
      |> result.replace_error(PriceUnavailable),
    )
    use price <- result.try(
      kraken_symbol
      |> kraken_symbol.apply_price_direction(price_entry.price)
      |> result.replace_error(ReciprocalOutOfRange),
    )

    Ok(RateResponse(
      rate_request.from,
      rate_request.to,
      Some(price),
      rate_response.Kraken,
      price_entry.timestamp,
    ))
  }

  case kraken_response {
    Ok(response) -> #(Ok(response), KrakenStrategy(kraken_symbol))
    Error(reason) -> {
      config.on_kraken_fallback(reason)
      execute_cmc_strategy(rate_request, config)
    }
  }
}

fn execute_cmc_strategy(
  rate_request: RateRequest,
  config: StrategyConfig,
) -> #(Result(RateResponse, RateError), RateSourceStrategy) {
  let response =
    rate_request
    |> cmc_rate_handler.get_rate(config.request_cmc_conversion)
    |> result.map_error(CmcError(rate_request, _))

  #(response, CmcStrategy)
}
