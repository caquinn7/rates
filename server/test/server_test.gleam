import gleam/erlang/atom.{type Atom}
import gleeunit
import server/integrations/kraken/price_store.{type PriceStore}

pub fn main() {
  gleeunit.main()
}

pub fn get_and_increment_test() {
  let key = "key"
  assert 0 == get_then_increment(key)
  assert 1 == get_then_increment(key)
  assert 2 == get_then_increment(key)

  assert 0 == get_then_increment("another_key")
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
///   price_store.insert(store, "BTC/USD", 50000.0)
///   // ... perform assertions ...
/// })
/// ```
pub fn with_price_store(fun: fn(PriceStore) -> a) {
  let assert Ok(store) = price_store.new()
  fun(store)
  price_store.drop(store)
}

/// Gets the current value of the counter and increments it
/// Returns the value BEFORE incrementing (0 on first call, 1 on second, etc.)
pub fn get_then_increment(counter_name: String) -> Int {
  let key = atom.create(counter_name)
  let current = get_or_zero(key)
  let _ = put_and_return_previous(key, current + 1)

  current
}

@external(erlang, "counter_ffi", "get_or_zero")
fn get_or_zero(key: Atom) -> Int

@external(erlang, "counter_ffi", "put_and_return_previous")
fn put_and_return_previous(key: Atom, value: Int) -> Int
