import gleeunit
import server/integrations/kraken/price_store.{type PriceStore}

pub fn main() {
  gleeunit.main()
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
///   store
///   |> price_store.insert("BTC/USD", 50000.0)
///   // ... perform assertions ...
/// })
/// ```
pub fn with_price_store(fun: fn(PriceStore) -> a) {
  let assert Ok(store) = price_store.new()
  fun(store)
  price_store.drop(store)
}
