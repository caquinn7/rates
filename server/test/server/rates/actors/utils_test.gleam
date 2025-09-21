import gleam/dict
import server/integrations/kraken/price_store.{PriceEntry}
import server/rates/actors/internal/kraken_symbol
import server/rates/actors/internal/utils.{CurrencyNotFound}
import server_test
import shared/rates/rate_request.{RateRequest}

pub fn resolve_currency_symbols_from_currency_not_found_test() {
  let currencies = dict.from_list([#(2781, "USD")])

  let result =
    RateRequest(1, 2781)
    |> utils.resolve_currency_symbols(currencies)

  assert Error(CurrencyNotFound(1)) == result
}

pub fn resolve_currency_symbols_to_currency_not_found_test() {
  let currencies = dict.from_list([#(1, "BTC")])

  let result =
    RateRequest(1, 2781)
    |> utils.resolve_currency_symbols(currencies)

  assert Error(CurrencyNotFound(2781)) == result
}

pub fn resolve_currency_symbols_test() {
  let currencies = dict.from_list([#(1, "BTC"), #(2781, "USD")])

  let result =
    RateRequest(1, 2781)
    |> utils.resolve_currency_symbols(currencies)

  assert Ok(#("BTC", "USD")) == result
}

pub fn wait_for_kraken_price_returns_error_when_price_not_found_test() {
  let assert Ok(kraken_symbol) =
    kraken_symbol.new_with_validator(#("BTC", "USD"), fn(_) { True })

  use store <- server_test.with_price_store

  let result = utils.wait_for_kraken_price(kraken_symbol, store, 1, 1)

  assert Error(Nil) == result
}

pub fn wait_for_kraken_price_returns_price_when_found_test() {
  let assert Ok(kraken_symbol) =
    kraken_symbol.new_with_validator(#("BTC", "USD"), fn(_) { True })

  use store <- server_test.with_price_store

  price_store.insert(store, "BTC/USD", 1.23)

  let assert Ok(PriceEntry(price, _)) =
    utils.wait_for_kraken_price(kraken_symbol, store, 1, 1)

  assert 1.23 == price
}
