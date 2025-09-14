import gleeunit/should
import server/integrations/kraken/price_store.{PriceEntry}
import server_test

pub fn unable_to_create_twice_test() {
  use _ <- server_test.with_price_store
  assert Error(Nil) == price_store.new()
}

pub fn insert_symbol_that_does_not_exist_test() {
  use store <- server_test.with_price_store

  let symbol = "BTC/USD"
  let expected_price = 90_000.0
  let expected_timestamp = 1

  price_store.insert_with_timestamp(
    store,
    symbol,
    expected_price,
    expected_timestamp,
  )

  let result = price_store.get_price(store, symbol)

  assert Ok(PriceEntry(expected_price, expected_timestamp)) == result
}

pub fn insert_symbol_that_exists_test() {
  use store <- server_test.with_price_store

  let symbol = "BTC/USD"
  let expected_price = 100_000.0
  let expected_timestamp = 2

  price_store.insert_with_timestamp(store, symbol, 90_000.0, 1)
  price_store.insert_with_timestamp(
    store,
    symbol,
    expected_price,
    expected_timestamp,
  )

  let result = price_store.get_price(store, symbol)

  assert Ok(PriceEntry(expected_price, expected_timestamp)) == result
}

pub fn get_price_for_symbol_that_does_not_exist() {
  use store <- server_test.with_price_store
  assert Error(Nil) == price_store.get_price(store, "BTC/USD")
}

pub fn get_store_test() {
  use _ <- server_test.with_price_store
  let assert Ok(_) = price_store.get_store()
}

pub fn get_store_returns_error_when_not_initialized() {
  price_store.get_store()
  |> should.be_error
  |> should.equal(Nil)
}

pub fn delete_existing_symbol_test() {
  use store <- server_test.with_price_store

  let symbol = "BTC/USD"
  price_store.insert_with_timestamp(store, symbol, 50_000.0, 1)

  // Verify it exists first
  let assert Ok(_) = price_store.get_price(store, symbol)

  // Delete it
  price_store.delete_price(store, symbol)

  // Verify it's gone
  assert Error(Nil) == price_store.get_price(store, symbol)
}

pub fn delete_non_existent_symbol_test() {
  use store <- server_test.with_price_store

  // Should not crash or cause errors
  price_store.delete_price(store, "NON_EXISTENT")

  // Store should still be functional
  price_store.insert_with_timestamp(store, "BTC/USD", 50_000.0, 1)
  let assert Ok(_) = price_store.get_price(store, "BTC/USD")
}

pub fn delete_one_symbol_preserves_others_test() {
  use store <- server_test.with_price_store

  price_store.insert_with_timestamp(store, "BTC/USD", 50_000.0, 1)
  price_store.insert_with_timestamp(store, "ETH/USD", 3000.0, 2)

  price_store.delete_price(store, "BTC/USD")

  // BTC/USD should be gone
  assert Error(Nil) == price_store.get_price(store, "BTC/USD")

  // ETH/USD should still be there
  assert Ok(PriceEntry(3000.0, 2)) == price_store.get_price(store, "ETH/USD")
}
