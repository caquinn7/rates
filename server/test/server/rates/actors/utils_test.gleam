import gleam/dict
import gleeunit/should
import server/kraken/price_store
import server/rates/actors/kraken_symbol
import server/rates/actors/utils.{CurrencyNotFound}
import server_test
import shared/rates/rate_request.{RateRequest}

pub fn resolve_currency_symbols_from_currency_not_found_test() {
  let currencies = dict.from_list([#(2781, "USD")])

  RateRequest(1, 2781)
  |> utils.resolve_currency_symbols(currencies)
  |> should.be_error
  |> should.equal(CurrencyNotFound(1))
}

pub fn resolve_currency_symbols_to_currency_not_found_test() {
  let currencies = dict.from_list([#(1, "BTC")])

  RateRequest(1, 2781)
  |> utils.resolve_currency_symbols(currencies)
  |> should.be_error
  |> should.equal(CurrencyNotFound(2781))
}

pub fn resolve_currency_symbols_test() {
  let currencies = dict.from_list([#(1, "BTC"), #(2781, "USD")])

  RateRequest(1, 2781)
  |> utils.resolve_currency_symbols(currencies)
  |> should.be_ok
  |> should.equal(#("BTC", "USD"))
}

pub fn wait_for_kraken_price_returns_error_when_price_not_found_test() {
  let assert Ok(kraken_symbol) =
    kraken_symbol.new_with_validator(#("BTC", "USD"), fn(_) { True })

  use store <- server_test.with_price_store

  let result =
    kraken_symbol
    |> utils.wait_for_kraken_price(store, 1, 1)

  assert Error(Nil) == result
}

pub fn wait_for_kraken_price_returns_price_when_found_test() {
  let assert Ok(kraken_symbol) =
    kraken_symbol.new_with_validator(#("BTC", "USD"), fn(_) { True })

  use store <- server_test.with_price_store

  store
  |> price_store.insert("BTC/USD", 1.23)

  let result =
    kraken_symbol
    |> utils.wait_for_kraken_price(store, 1, 1)

  assert Ok(1.23) == result
}
