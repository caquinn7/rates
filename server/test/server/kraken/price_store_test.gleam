import gleeunit/should
import server/kraken/price_store
import server_test

pub fn unable_to_create_twice_test() {
  use _ <- server_test.with_price_store

  price_store.new()
  |> should.be_error
  |> should.equal(Nil)
}

pub fn insert_symbol_that_does_not_exist_test() {
  use store <- server_test.with_price_store

  let symbol = "BTC/USD"
  let expected_price = 90_000.0

  store
  |> price_store.insert(symbol, expected_price)

  store
  |> price_store.get_price(symbol)
  |> should.be_ok
  |> should.equal(expected_price)
}

pub fn insert_symbol_that_exists_test() {
  use store <- server_test.with_price_store

  let symbol = "BTC/USD"
  let expected_price = 100_000.0

  store
  |> price_store.insert(symbol, 90_000.0)

  store
  |> price_store.insert(symbol, expected_price)

  store
  |> price_store.get_price(symbol)
  |> should.be_ok
  |> should.equal(expected_price)
}

pub fn get_price_for_symbol_that_does_not_exist() {
  use store <- server_test.with_price_store

  store
  |> price_store.get_price("BTC/USD")
  |> should.be_error
  |> should.equal(Nil)
}

pub fn get_store_test() {
  use _ <- server_test.with_price_store

  price_store.get_store()
  |> should.be_ok
}

pub fn get_store_returns_error_when_not_initialized() {
  price_store.get_store()
  |> should.be_error
  |> should.equal(Nil)
}
