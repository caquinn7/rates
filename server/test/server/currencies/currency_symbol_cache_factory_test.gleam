import gleam/erlang/process
import gleam/httpc
import gleam/option.{None, Some}
import server/currencies/cmc_currency_handler.{ClientError, MissingData}
import server/currencies/currency_repository.{CurrencyRepository}
import server/currencies/currency_symbol_cache
import server/currencies/currency_symbol_cache_factory
import server/integrations/coin_market_cap/client.{
  CmcResponse, CmcStatus, HttpError,
}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  CmcCryptoCurrency,
}
import shared/currency.{Crypto}

pub fn missing_data_reports_error_and_keeps_cache_available_test() {
  let errors = process.new_subject()
  let inserts = process.new_subject()
  let repository =
    CurrencyRepository(
      insert: process.send(inserts, _),
      get_by_id: fn(_) { panic },
      get_by_symbol: fn(_) { [] },
      get_all: fn() { panic },
    )
  let status = CmcStatus(0, None)
  let request_cryptos = fn(symbol) {
    case symbol {
      Some("BAD") -> Ok(CmcResponse(status, None))
      Some("BTC") ->
        Ok(CmcResponse(
          status,
          Some([CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")]),
        ))
      _ -> panic as "Unexpected symbol request"
    }
  }
  let cache =
    currency_symbol_cache_factory.create(
      repository,
      request_cryptos,
      process.send(errors, _),
    )

  assert currency_symbol_cache.get_by_symbol(cache, "BAD") == Error(Nil)
  assert process.receive(errors, 1000) == Ok(MissingData(status))
  assert process.receive(inserts, 0) == Error(Nil)

  let expected = [Crypto(1, "Bitcoin", "BTC", Some(1))]
  assert currency_symbol_cache.get_by_symbol(cache, "BTC") == Ok(expected)
  assert process.receive(inserts, 1000) == Ok(expected)
  assert process.receive(errors, 0) == Error(Nil)
  assert process.receive(inserts, 0) == Error(Nil)
}

pub fn symbol_request_timeout_reports_error_and_returns_lookup_failure_test() {
  let subject = process.new_subject()
  let repository =
    CurrencyRepository(
      insert: fn(_) { panic as "A timed-out request must not insert currencies" },
      get_by_id: fn(_) { panic },
      get_by_symbol: fn(_) { [] },
      get_all: fn() { panic },
    )
  let timeout = HttpError(httpc.ResponseTimeout)
  let request_cryptos = fn(symbol) {
    assert symbol == Some("BTC")
    Error(timeout)
  }
  let cache =
    currency_symbol_cache_factory.create(
      repository,
      request_cryptos,
      process.send(subject, _),
    )

  assert currency_symbol_cache.get_by_symbol(cache, "BTC") == Error(Nil)
  assert process.receive(subject, 1000) == Ok(ClientError(timeout))
  assert process.receive(subject, 0) == Error(Nil)
}
