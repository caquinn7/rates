import gleam/dict
import gleam/option.{None, Some}
import server/domain/rates/internal/kraken_symbol
import server/domain/rates/internal/rate_source_strategy.{
  CmcStrategy, CurrencyNotFound, KrakenStrategy, StrategyBehavior,
  StrategyConfig,
}
import server/domain/rates/rate_error.{CmcError}
import server/integrations/coin_market_cap/client.{
  type CmcConversionParameters, CmcResponse, CmcStatus,
}
import server/integrations/coin_market_cap/cmc_conversion.{
  CmcConversion, QuoteItem,
}
import server/integrations/kraken/price_store.{PriceEntry}
import shared/currency.{Crypto, Fiat}
import shared/rates/rate_request.{RateRequest}
import shared/rates/rate_response

const btc = Crypto(1, "Bitcoin", "BTC", Some(1))

const usd = Fiat(2781, "US Dollar", "USD", "$")

pub fn determine_strategy_returns_currency_not_found_when_first_currency_id_not_found_test() {
  let rate_request = RateRequest(from: 1, to: 2)
  let get_currency_by_id = fn(id) {
    case id {
      2 -> Ok(usd)
      _ -> Error(Nil)
    }
  }
  let create_kraken_symbol = fn(_) {
    panic as "Should not be called - kraken symbol failure not expected"
  }

  let result =
    rate_source_strategy.determine_strategy(
      rate_request,
      get_currency_by_id,
      create_kraken_symbol,
    )

  assert Error(CurrencyNotFound(1)) == result
}

pub fn determine_strategy_returns_currency_not_found_when_second_currency_id_not_found_test() {
  let rate_request = RateRequest(from: 1, to: 2)
  let get_currency_by_id = fn(id) {
    case id {
      1 -> Ok(btc)
      _ -> Error(Nil)
    }
  }
  let create_kraken_symbol = fn(_) {
    panic as "Should not be called - kraken symbol failure not expected"
  }

  let result =
    rate_source_strategy.determine_strategy(
      rate_request,
      get_currency_by_id,
      create_kraken_symbol,
    )

  assert Error(CurrencyNotFound(2)) == result
}

pub fn determine_strategy_returns_kraken_strategy_when_symbol_resolved_test() {
  let rate_request = RateRequest(from: 1, to: 2)
  let get_currency_by_id = fn(id) {
    case id {
      1 -> Ok(btc)
      2 -> Ok(usd)
      _ -> Error(Nil)
    }
  }
  let create_kraken_symbol = kraken_symbol.new(_, fn(_) { True })

  let assert Ok(KrakenStrategy(_)) =
    rate_source_strategy.determine_strategy(
      rate_request,
      get_currency_by_id,
      create_kraken_symbol,
    )
}

pub fn determine_strategy_returns_cmc_strategy_when_symbol_not_resolved_test() {
  let rate_request = RateRequest(from: 1, to: 2)
  let get_currency_by_id = fn(id) {
    case id {
      1 -> Ok(btc)
      2 -> Ok(usd)
      _ -> Error(Nil)
    }
  }
  let create_kraken_symbol = kraken_symbol.new(_, fn(_) { False })

  let result =
    rate_source_strategy.determine_strategy(
      rate_request,
      get_currency_by_id,
      create_kraken_symbol,
    )

  assert Ok(CmcStrategy) == result
}

pub fn execute_strategy_returns_kraken_response_when_kraken_price_is_found_test() {
  let rate_request = RateRequest(from: 1, to: 2)
  let get_currency_by_id = fn(id) {
    case id {
      1 -> Ok(btc)
      2 -> Ok(usd)
      _ -> Error(Nil)
    }
  }

  let create_kraken_symbol = kraken_symbol.new(_, fn(_) { True })
  let assert Ok(strategy) =
    rate_source_strategy.determine_strategy(
      rate_request,
      get_currency_by_id,
      create_kraken_symbol,
    )

  let assert KrakenStrategy(_) = strategy

  let config =
    StrategyConfig(
      check_for_kraken_price: fn(_) {
        Ok(PriceEntry(price: 50_000.0, timestamp: 1000))
      },
      request_cmc_conversion: fn(_) {
        panic as "Should not call CMC on Kraken success"
      },
      get_current_time_ms: fn() { 1000 },
      behavior: StrategyBehavior(
        on_kraken_success: fn() { Nil },
        on_kraken_failure: fn(_, _) { panic as "Kraken failure not expected" },
      ),
    )

  let #(result, should_downgrade) =
    rate_source_strategy.execute_strategy(strategy, rate_request, config)

  let assert Ok(response) = result
  assert 1 == response.from
  assert 2 == response.to
  assert Some(50_000.0) == response.rate
  assert rate_response.Kraken == response.source
  assert 1000 == response.timestamp
  assert False == should_downgrade
}

pub fn execute_strategy_falls_back_to_cmc_when_kraken_price_not_found_test() {
  let rate_request = RateRequest(from: 1, to: 2)
  let get_currency_by_id = fn(id) {
    case id {
      1 -> Ok(btc)
      2 -> Ok(usd)
      _ -> Error(Nil)
    }
  }

  let create_kraken_symbol = kraken_symbol.new(_, fn(_) { True })
  let assert Ok(strategy) =
    rate_source_strategy.determine_strategy(
      rate_request,
      get_currency_by_id,
      create_kraken_symbol,
    )

  let assert KrakenStrategy(_) = strategy

  let request_cmc_conversion = fn(conversion_params: CmcConversionParameters) {
    Ok(CmcResponse(
      CmcStatus(0, None),
      Some(CmcConversion(
        conversion_params.id,
        "BTC",
        "Bitcoin",
        1.0,
        dict.from_list([#("2", QuoteItem(Some(100_000.0)))]),
      )),
    ))
  }

  let config =
    StrategyConfig(
      check_for_kraken_price: fn(_) { Error(Nil) },
      request_cmc_conversion:,
      get_current_time_ms: fn() { 1000 },
      behavior: StrategyBehavior(
        on_kraken_success: fn() { panic as "Kraken success not expected" },
        on_kraken_failure: fn(_, _) { Nil },
      ),
    )

  let #(result, should_downgrade) =
    rate_source_strategy.execute_strategy(strategy, rate_request, config)

  let assert Ok(response) = result
  assert 1 == response.from
  assert 2 == response.to
  assert Some(100_000.0) == response.rate
  assert rate_response.CoinMarketCap == response.source
  assert 1000 == response.timestamp
  assert True == should_downgrade
}

pub fn execute_strategy_returns_cmc_response_when_successful_test() {
  let rate_request = RateRequest(1, 2)

  let cmc_get_rate = fn(conversion_params: CmcConversionParameters) {
    Ok(CmcResponse(
      CmcStatus(0, None),
      Some(CmcConversion(
        conversion_params.id,
        "BTC",
        "Bitcoin",
        1.0,
        dict.from_list([#("2", QuoteItem(Some(100_000.0)))]),
      )),
    ))
  }

  let config =
    StrategyConfig(
      check_for_kraken_price: fn(_) { Error(Nil) },
      request_cmc_conversion: cmc_get_rate,
      get_current_time_ms: fn() { 1000 },
      behavior: StrategyBehavior(
        on_kraken_success: fn() {
          panic as "Should not be called for CMC strategy"
        },
        on_kraken_failure: fn(_, _) {
          panic as "Should not be called for CMC strategy"
        },
      ),
    )

  let #(result, should_downgrade) =
    rate_source_strategy.execute_strategy(CmcStrategy, rate_request, config)

  let assert Ok(response) = result
  assert 1 == response.from
  assert 2 == response.to
  assert Some(100_000.0) == response.rate
  assert rate_response.CoinMarketCap == response.source
  assert 1000 == response.timestamp
  assert False == should_downgrade
}

pub fn execute_strategy_returns_error_when_cmc_fails_test() {
  let rate_request = RateRequest(from: 1, to: 2)
  let get_currency_by_id = fn(id) {
    case id {
      1 -> Ok(btc)
      2 -> Ok(usd)
      _ -> Error(Nil)
    }
  }

  let create_kraken_symbol = kraken_symbol.new(_, fn(_) { False })
  let assert Ok(strategy) =
    rate_source_strategy.determine_strategy(
      rate_request,
      get_currency_by_id,
      create_kraken_symbol,
    )

  assert CmcStrategy == strategy

  let request_cmc_conversion = fn(_) {
    Ok(CmcResponse(CmcStatus(400, Some("")), None))
  }

  let config =
    StrategyConfig(
      check_for_kraken_price: fn(_) {
        panic as "Should not call Kraken for CMC strategy"
      },
      request_cmc_conversion: request_cmc_conversion,
      get_current_time_ms: fn() { 1000 },
      behavior: StrategyBehavior(
        on_kraken_success: fn() { Nil },
        on_kraken_failure: fn(_, _) { Nil },
      ),
    )

  let #(result, should_downgrade) =
    rate_source_strategy.execute_strategy(strategy, rate_request, config)

  let assert Error(CmcError(req, _)) = result
  assert req == rate_request
  assert !should_downgrade
}
