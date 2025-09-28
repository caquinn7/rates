import gleam/dict.{type Dict}
import gleam/result
import server/domain/rates/internal/cmc_rate_handler.{type RequestCmcConversion}
import server/domain/rates/internal/kraken_symbol.{type KrakenSymbol}
import server/domain/rates/internal/utils
import server/domain/rates/rate_error.{type RateError, CmcError}
import server/integrations/kraken/price_store.{type PriceEntry}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse, RateResponse}

pub type RateSourceStrategy {
  KrakenStrategy(KrakenSymbol)
  CmcStrategy
}

pub type StrategyError {
  CurrencyNotFound(Int)
}

pub type StrategyBehavior {
  StrategyBehavior(
    on_kraken_success: fn() -> Nil,
    on_kraken_failure: fn(RateRequest, KrakenSymbol) -> Nil,
  )
}

pub type StrategyConfig {
  StrategyConfig(
    check_for_kraken_price: fn(KrakenSymbol) -> Result(PriceEntry, Nil),
    request_cmc_conversion: RequestCmcConversion,
    get_current_time_ms: fn() -> Int,
    behavior: StrategyBehavior,
  )
}

pub fn determine_strategy(
  rate_request: RateRequest,
  currency_symbols: Dict(Int, String),
  create_kraken_symbol: fn(#(String, String)) -> Result(KrakenSymbol, Nil),
) -> Result(RateSourceStrategy, StrategyError) {
  use symbols <- result.try(
    rate_request
    |> utils.resolve_currency_symbols(currency_symbols)
    |> result.map_error(fn(err) {
      case err {
        utils.CurrencyNotFound(id) -> CurrencyNotFound(id)
      }
    }),
  )

  Ok(case create_kraken_symbol(symbols) {
    Ok(symbol) -> KrakenStrategy(symbol)
    Error(_) -> CmcStrategy
  })
}

pub fn execute_strategy(
  strategy: RateSourceStrategy,
  rate_request: RateRequest,
  config: StrategyConfig,
) -> Result(RateResponse, RateError) {
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
) -> Result(RateResponse, RateError) {
  let kraken_price_result = config.check_for_kraken_price(kraken_symbol)
  case kraken_price_result {
    Error(_) -> {
      config.behavior.on_kraken_failure(rate_request, kraken_symbol)
      execute_cmc_strategy(rate_request, config)
    }

    Ok(price_entry) -> {
      config.behavior.on_kraken_success()

      let price =
        kraken_symbol.apply_price_direction(kraken_symbol, price_entry.price)

      Ok(RateResponse(
        rate_request.from,
        rate_request.to,
        price,
        rate_response.Kraken,
        price_entry.timestamp,
      ))
    }
  }
}

fn execute_cmc_strategy(
  rate_request: RateRequest,
  config: StrategyConfig,
) -> Result(RateResponse, RateError) {
  rate_request
  |> cmc_rate_handler.get_rate(
    config.request_cmc_conversion,
    config.get_current_time_ms,
  )
  |> result.map_error(CmcError(rate_request, _))
}
