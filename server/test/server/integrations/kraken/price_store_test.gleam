import exception
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import server/integrations/kraken/price_store.{type PriceStore, PriceEntry}
import shared/numbers/positive_float

pub fn stores_can_cache_different_quotes_for_the_same_symbol_test() {
  let assert Ok(first) = price_store.new()
  let assert Ok(second) = price_store.new()
  let symbol = "BTC/USD"
  let first_price = positive_float.from_float_unsafe(90_000.0)
  let second_price = positive_float.from_float_unsafe(100_000.0)
  price_store.insert(first, symbol, first_price, 1)
  price_store.insert(second, symbol, second_price, 2)

  assert price_store.get_price(first, symbol) == Ok(PriceEntry(first_price, 1))
  assert price_store.get_price(second, symbol)
    == Ok(PriceEntry(second_price, 2))
}

pub fn insert_symbol_that_does_not_exist_test() {
  let assert Ok(store) = price_store.new()

  let symbol = "BTC/USD"
  let expected_price = positive_float.from_float_unsafe(90_000.0)
  let expected_timestamp = 1

  price_store.insert(store, symbol, expected_price, expected_timestamp)

  let result = price_store.get_price(store, symbol)

  assert Ok(PriceEntry(expected_price, expected_timestamp)) == result
}

pub fn insert_symbol_that_exists_test() {
  let assert Ok(store) = price_store.new()

  let symbol = "BTC/USD"
  let first_price = positive_float.from_float_unsafe(90_000.0)
  let expected_price = positive_float.from_float_unsafe(100_000.0)
  let expected_timestamp = 2

  price_store.insert(store, symbol, first_price, 1)
  price_store.insert(store, symbol, expected_price, expected_timestamp)

  let result = price_store.get_price(store, symbol)

  assert Ok(PriceEntry(expected_price, expected_timestamp)) == result
}

pub fn get_price_for_symbol_that_does_not_exist_test() {
  let assert Ok(store) = price_store.new()
  assert Error(Nil) == price_store.get_price(store, "BTC/USD")
}

pub fn non_owner_can_read_price_through_handle_test() {
  let assert Ok(store) = price_store.new()

  let price = positive_float.from_float_unsafe(90_000.0)
  price_store.insert(store, "BTC/USD", price, 1)

  let result =
    in_other_process(fn() { price_store.get_price(store, "BTC/USD") })

  assert result == Ok(PriceEntry(price, 1))
}

pub fn non_owner_cannot_insert_price_test() {
  assert_non_owner_cannot_mutate(fn(store) {
    price_store.insert(
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

pub fn owner_exit_invalidates_the_price_store_handle_test() {
  let symbol = "BTC/USD"
  let ready = process.new_subject()
  let price = positive_float.from_float_unsafe(90_000.0)

  let owner =
    process.spawn(fn() {
      let stop = process.new_subject()
      let assert Ok(store) = price_store.new()
      price_store.insert(store, symbol, price, 1)
      process.send(ready, #(store, stop))

      let assert Ok(Nil) = process.receive(stop, 1000)
      Nil
    })
  use <- exception.defer(fn() { stop_process(owner) })

  let monitor = process.monitor(owner)
  let assert Ok(#(original, stop)) = process.receive(ready, 1000)
  assert price_store.get_price(original, symbol) == Ok(PriceEntry(price, 1))

  process.send(stop, Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)

  let assert Ok(replacement) = price_store.new()
  let replacement_price = positive_float.from_float_unsafe(100_000.0)
  price_store.insert(replacement, symbol, replacement_price, 2)
  assert price_store.get_price(replacement, symbol)
    == Ok(PriceEntry(replacement_price, 2))

  let assert Error(exception.Errored(reason)) =
    exception.rescue(fn() { price_store.get_price(original, symbol) })
  assert decode.run(reason, atom.decoder()) == Ok(atom.create("badarg"))
}

pub fn delete_existing_symbol_test() {
  let assert Ok(store) = price_store.new()

  let symbol = "BTC/USD"
  price_store.insert(
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
  let assert Ok(store) = price_store.new()

  // Should not crash or cause errors
  price_store.delete_price(store, "NON_EXISTENT")

  // Store should still be functional
  price_store.insert(
    store,
    "BTC/USD",
    positive_float.from_float_unsafe(50_000.0),
    1,
  )
  let assert Ok(_) = price_store.get_price(store, "BTC/USD")
}

pub fn delete_one_symbol_preserves_others_test() {
  let assert Ok(store) = price_store.new()

  let btc_price = positive_float.from_float_unsafe(50_000.0)
  let eth_price = positive_float.from_float_unsafe(3000.0)

  price_store.insert(store, "BTC/USD", btc_price, 1)
  price_store.insert(store, "ETH/USD", eth_price, 2)

  price_store.delete_price(store, "BTC/USD")

  // BTC/USD should be gone
  assert Error(Nil) == price_store.get_price(store, "BTC/USD")

  // ETH/USD should still be there
  assert Ok(PriceEntry(eth_price, 2)) == price_store.get_price(store, "ETH/USD")
}

fn assert_non_owner_cannot_mutate(mutate: fn(PriceStore) -> Nil) {
  let assert Ok(store) = price_store.new()

  let price = positive_float.from_float_unsafe(90_000.0)
  price_store.insert(store, "BTC/USD", price, 1)

  let assert Error(exception.Errored(reason)) =
    in_other_process(fn() { exception.rescue(fn() { mutate(store) }) })

  assert decode.run(reason, atom.decoder()) == Ok(atom.create("badarg"))
  assert price_store.get_price(store, "BTC/USD") == Ok(PriceEntry(price, 1))
}

/// Runs `run` in a separate linked process and returns its result.
///
/// Lets tests exercise store access from a process that does not own the ETS table.
/// A result must arrive within one second or the test fails. Unexpected worker
/// crashes propagate through the process link. Deferred cleanup stops the worker
/// and waits for its exit, even if waiting for the result fails.
fn in_other_process(run: fn() -> a) -> a {
  let subject = process.new_subject()
  let worker = process.spawn(fn() { process.send(subject, run()) })
  use <- exception.defer(fn() { stop_process(worker) })

  let assert Ok(value) = process.receive(subject, 1000)
  value
}

/// Stops a test worker and waits for confirmation that it has exited.
///
/// Unlinks it first so killing it does not terminate the calling test process.
/// Monitors it before sending the kill signal so its exit notification is not
/// missed. Fails the test if no notification arrives within one second.
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
