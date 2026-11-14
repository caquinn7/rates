import gleam/erlang/process
import gleam/httpc
import gleam/option.{Some}
import server/currencies/cmc_currency_handler.{ClientError}
import server/currencies/currency_repository.{CurrencyRepository}
import server/currencies/currency_symbol_cache
import server/currencies/currency_symbol_cache_factory
import server/integrations/coin_market_cap/client.{HttpError}

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
