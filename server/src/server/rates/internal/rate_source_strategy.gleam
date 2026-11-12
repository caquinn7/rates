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
  /// Tries Kraken, falling back to CoinMarketCap if no price is available.
  /// Carries the resolved Kraken pair and its price direction.
  KrakenStrategy(KrakenSymbol)

  /// Requests a CoinMarketCap conversion directly.
  /// Selected when no supported Kraken pair can be resolved.
  CmcStrategy
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
    /// Called before requesting CMC when a Kraken price lookup fails.
    on_kraken_fallback: fn() -> Nil,
  )
}

/// Resolves the requested currency IDs to symbols and selects a lookup strategy.
/// Uses Kraken when `create_kraken_symbol` succeeds, otherwise CoinMarketCap.
///
/// Returns `CurrencyNotFound` with the original request and the first currency ID
/// that `get_currency_by_id` cannot resolve.
pub fn determine_strategy(
  rate_request: RateRequest,
  get_currency_by_id: fn(Int) -> Result(Currency, Nil),
  create_kraken_symbol: fn(#(String, String)) -> Result(KrakenSymbol, Nil),
) -> Result(RateSourceStrategy, RateError) {
  use symbols <- result.try(
    rate_request
    |> resolve_currency_symbols(get_currency_by_id)
    |> result.map_error(CurrencyNotFound(rate_request, _)),
  )

  Ok(case create_kraken_symbol(symbols) {
    Ok(symbol) -> KrakenStrategy(symbol)
    Error(_) -> CmcStrategy
  })
}

fn resolve_currency_symbols(
  rate_request: RateRequest,
  get_currency_by_id: fn(Int) -> Result(Currency, Nil),
) -> Result(#(String, String), Int) {
  let try_get_symbol = fn(id) {
    id
    |> get_currency_by_id
    |> result.replace_error(id)
    |> result.map(fn(currency) { currency.symbol })
  }

  use from_symbol <- result.try(try_get_symbol(rate_request.from))
  use to_symbol <- result.try(try_get_symbol(rate_request.to))
  Ok(#(from_symbol, to_symbol))
}

/// Fetches a quote using the selected strategy, falling back from Kraken to CMC
/// when the Kraken lookup fails. Calls `on_kraken_fallback` before that CMC request.
///
/// Returns `#(result, fell_back_from_kraken)`. The flag is `True` when a failed
/// Kraken lookup led to a CMC request, even if that request fails. It is `False`
/// for a successful Kraken lookup or a direct CMC strategy.
pub fn execute_strategy(
  strategy: RateSourceStrategy,
  rate_request: RateRequest,
  config: StrategyConfig,
) -> #(Result(RateResponse, RateError), Bool) {
  case strategy {
    KrakenStrategy(symbol) ->
      execute_kraken_strategy(rate_request, symbol, config)

    CmcStrategy -> #(execute_cmc_strategy(rate_request, config), False)
  }
}

fn execute_kraken_strategy(
  rate_request: RateRequest,
  kraken_symbol: KrakenSymbol,
  config: StrategyConfig,
) -> #(Result(RateResponse, RateError), Bool) {
  let kraken_price_result = config.check_for_kraken_price(kraken_symbol)
  case kraken_price_result {
    Error(_) -> {
      config.on_kraken_fallback()
      #(execute_cmc_strategy(rate_request, config), True)
    }

    Ok(price_entry) -> {
      let price =
        kraken_symbol.apply_price_direction(kraken_symbol, price_entry.price)

      #(
        Ok(RateResponse(
          rate_request.from,
          rate_request.to,
          Some(price),
          rate_response.Kraken,
          price_entry.timestamp,
        )),
        False,
      )
    }
  }
}

fn execute_cmc_strategy(
  rate_request: RateRequest,
  config: StrategyConfig,
) -> Result(RateResponse, RateError) {
  rate_request
  |> cmc_rate_handler.get_rate(config.request_cmc_conversion)
  |> result.map_error(CmcError(rate_request, _))
}
