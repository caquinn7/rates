import gleam/dict
import gleam/set
import gleeunit/should
import server/kraken/pairs
import server/kraken/price_store
import server/rates/actors/utils.{CurrencyNotFound, SymbolDirect, SymbolReversed}
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

pub fn resolve_kraken_symbol_direct_symbol_exists_test() {
  pairs.clear()
  pairs.set(set.from_list(["BASE/QUOTE"]))

  let result =
    #("BASE", "QUOTE")
    |> utils.resolve_kraken_symbol
    |> should.be_ok

  result
  |> utils.unwrap_kraken_symbol
  |> should.equal("BASE/QUOTE")

  result
  |> utils.unwrap_kraken_symbol_direction
  |> should.equal(SymbolDirect)
}

pub fn resolve_kraken_symbol_reversed_symbol_exists_test() {
  pairs.clear()
  pairs.set(set.from_list(["BASE/QUOTE"]))

  let result =
    #("QUOTE", "BASE")
    |> utils.resolve_kraken_symbol
    |> should.be_ok

  result
  |> utils.unwrap_kraken_symbol
  |> should.equal("BASE/QUOTE")

  result
  |> utils.unwrap_kraken_symbol_direction
  |> should.equal(SymbolReversed)
}

pub fn resolve_kraken_symbol_symbol_not_found_test() {
  pairs.clear()
  pairs.set(set.new())

  #("BTC", "USD")
  |> utils.resolve_kraken_symbol
  |> should.be_error
}

pub fn wait_for_kraken_price_price_not_found_test() {
  pairs.clear()
  pairs.set(set.from_list(["BASE/QUOTE"]))
  let assert Ok(kraken_symbol) = utils.resolve_kraken_symbol(#("BASE", "QUOTE"))

  use store <- server_test.with_price_store

  kraken_symbol
  |> utils.wait_for_kraken_price(store, 1, 1)
  |> should.be_error
  |> should.equal(Nil)
}

pub fn wait_for_kraken_price_price_found_test() {
  pairs.clear()
  pairs.set(set.from_list(["BASE/QUOTE"]))
  let assert Ok(kraken_symbol) = utils.resolve_kraken_symbol(#("BASE", "QUOTE"))

  use store <- server_test.with_price_store

  store
  |> price_store.insert("BASE/QUOTE", 1.23)

  kraken_symbol
  |> utils.wait_for_kraken_price(store, 1, 1)
  |> should.be_ok
  |> should.equal(1.23)
}
