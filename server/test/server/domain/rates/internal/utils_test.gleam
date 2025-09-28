import server/domain/rates/internal/kraken_symbol
import server/domain/rates/internal/utils
import server/integrations/kraken/price_store.{PriceEntry}
import server_test

pub fn wait_for_kraken_price_returns_error_when_price_not_found_test() {
  let assert Ok(kraken_symbol) =
    kraken_symbol.new(#("BTC", "USD"), fn(_) { True })

  use store <- server_test.with_price_store

  let result = utils.wait_for_kraken_price(kraken_symbol, store, 1, 1)

  assert Error(Nil) == result
}

pub fn wait_for_kraken_price_returns_price_when_found_test() {
  let assert Ok(kraken_symbol) =
    kraken_symbol.new(#("BTC", "USD"), fn(_) { True })

  use store <- server_test.with_price_store

  price_store.insert(store, "BTC/USD", 1.23)

  let assert Ok(PriceEntry(price, _)) =
    utils.wait_for_kraken_price(kraken_symbol, store, 1, 1)

  assert 1.23 == price
}
