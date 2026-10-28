import exception
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleeunit/should
import server/integrations/kraken/price_store.{type PriceStore, PriceEntry}
import shared/positive_float

pub fn unable_to_create_twice_test() {
  use _ <- with_price_store
  assert Error(Nil) == price_store.new()
}

pub fn insert_symbol_that_does_not_exist_test() {
  use store <- with_price_store

  let symbol = "BTC/USD"
  let expected_price = positive_float.from_float_unsafe(90_000.0)
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
  use store <- with_price_store

  let symbol = "BTC/USD"
  let first_price = positive_float.from_float_unsafe(90_000.0)
  let expected_price = positive_float.from_float_unsafe(100_000.0)
  let expected_timestamp = 2

  price_store.insert_with_timestamp(store, symbol, first_price, 1)
  price_store.insert_with_timestamp(
    store,
    symbol,
    expected_price,
    expected_timestamp,
  )

  let result = price_store.get_price(store, symbol)

  assert Ok(PriceEntry(expected_price, expected_timestamp)) == result
}

pub fn get_price_for_symbol_that_does_not_exist_test() {
  use store <- with_price_store
  assert Error(Nil) == price_store.get_price(store, "BTC/USD")
}

pub fn get_store_test() {
  use store <- with_price_store

  let price = positive_float.from_float_unsafe(90_000.0)
  price_store.insert_with_timestamp(store, "BTC/USD", price, 1)

  let assert Ok(retrieved_store) = price_store.get_store()
  assert price_store.get_price(retrieved_store, "BTC/USD")
    == Ok(PriceEntry(price, 1))
}

pub fn get_store_returns_error_when_not_initialized_test() {
  price_store.get_store()
  |> should.be_error
  |> should.equal(Nil)
}

pub fn get_store_returns_error_after_table_is_dropped_test() {
  let assert Ok(store) = price_store.new()
  price_store.drop(store)

  assert price_store.get_store() == Error(Nil)
}

pub fn non_owner_can_get_store_and_read_price_test() {
  use store <- with_price_store

  let price = positive_float.from_float_unsafe(90_000.0)
  price_store.insert_with_timestamp(store, "BTC/USD", price, 1)

  let result =
    in_other_process(fn() {
      let assert Ok(retrieved_store) = price_store.get_store()
      price_store.get_price(retrieved_store, "BTC/USD")
    })

  assert result == Ok(PriceEntry(price, 1))
}

pub fn non_owner_cannot_insert_price_test() {
  assert_non_owner_cannot_mutate(fn(store) {
    price_store.insert_with_timestamp(
      store,
      "BTC/USD",
      positive_float.from_float_unsafe(100_000.0),
      2,
    )
  })
}

pub fn non_owner_cannot_delete_price_test() {
  assert_non_owner_cannot_mutate(fn(store) {
    price_store.delete_price(store, "BTC/USD")
  })
}

pub fn non_owner_cannot_drop_store_test() {
  assert_non_owner_cannot_mutate(price_store.drop)
}

pub fn owner_exit_removes_table_and_allows_recreation_test() {
  let ready = process.new_subject()
  let price = positive_float.from_float_unsafe(90_000.0)

  let owner =
    process.spawn(fn() {
      let stop = process.new_subject()
      let assert Ok(store) = price_store.new()
      price_store.insert_with_timestamp(store, "BTC/USD", price, 1)
      process.send(ready, stop)

      let assert Ok(Nil) = process.receive(stop, 1000)
      Nil
    })
  use <- exception.defer(fn() { stop_process(owner) })

  let monitor = process.monitor(owner)
  let assert Ok(stop) = process.receive(ready, 1000)
  let assert Ok(store) = price_store.get_store()
  assert price_store.get_price(store, "BTC/USD") == Ok(PriceEntry(price, 1))

  process.send(stop, Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)

  assert price_store.get_store() == Error(Nil)
  with_price_store(fn(_) { Nil })
}

pub fn delete_existing_symbol_test() {
  use store <- with_price_store

  let symbol = "BTC/USD"
  price_store.insert_with_timestamp(
    store,
    symbol,
    positive_float.from_float_unsafe(50_000.0),
    1,
  )

  // Verify it exists first
  let assert Ok(_) = price_store.get_price(store, symbol)

  // Delete it
  price_store.delete_price(store, symbol)

  // Verify it's gone
  assert Error(Nil) == price_store.get_price(store, symbol)
}

pub fn delete_non_existent_symbol_test() {
  use store <- with_price_store

  // Should not crash or cause errors
  price_store.delete_price(store, "NON_EXISTENT")

  // Store should still be functional
  price_store.insert_with_timestamp(
    store,
    "BTC/USD",
    positive_float.from_float_unsafe(50_000.0),
    1,
  )
  let assert Ok(_) = price_store.get_price(store, "BTC/USD")
}

pub fn delete_one_symbol_preserves_others_test() {
  use store <- with_price_store

  let btc_price = positive_float.from_float_unsafe(50_000.0)
  let eth_price = positive_float.from_float_unsafe(3000.0)

  price_store.insert_with_timestamp(store, "BTC/USD", btc_price, 1)
  price_store.insert_with_timestamp(store, "ETH/USD", eth_price, 2)

  price_store.delete_price(store, "BTC/USD")

  // BTC/USD should be gone
  assert Error(Nil) == price_store.get_price(store, "BTC/USD")

  // ETH/USD should still be there
  assert Ok(PriceEntry(eth_price, 2)) == price_store.get_price(store, "ETH/USD")
}

/// Creates a new `PriceStore`, passes it to the given function, and ensures
/// the store is dropped afterward to avoid lingering state between tests.
///
/// This utility is intended for use in tests that require a fresh, isolated
/// `PriceStore` instance. It ensures proper cleanup regardless of what the
/// provided function does.
///
/// ## Example
/// ```gleam
/// with_price_store(fn(store) {
///   let assert Ok(price) = positive_float.new(50_000.0)
///   price_store.insert(store, "BTC/USD", price)
///   // ... perform assertions ...
/// })
/// ```
fn with_price_store(fun: fn(PriceStore) -> a) {
  let assert Ok(store) = price_store.new()
  use <- exception.defer(fn() { price_store.drop(store) })
  fun(store)
}

fn assert_non_owner_cannot_mutate(mutate: fn(PriceStore) -> Nil) {
  use store <- with_price_store

  let price = positive_float.from_float_unsafe(90_000.0)
  price_store.insert_with_timestamp(store, "BTC/USD", price, 1)

  let assert Error(exception.Errored(reason)) =
    in_other_process(fn() { exception.rescue(fn() { mutate(store) }) })

  assert decode.run(reason, atom.decoder()) == Ok(atom.create("badarg"))
  assert price_store.get_price(store, "BTC/USD") == Ok(PriceEntry(price, 1))
}

fn in_other_process(run: fn() -> a) -> a {
  let reply = process.new_subject()
  let worker = process.spawn(fn() { process.send(reply, run()) })
  use <- exception.defer(fn() { stop_process(worker) })

  let assert Ok(value) = process.receive(reply, 1000)
  value
}

fn stop_process(pid: process.Pid) {
  process.unlink(pid)
  let monitor = process.monitor(pid)
  process.kill(pid)

  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)

  Nil
}
