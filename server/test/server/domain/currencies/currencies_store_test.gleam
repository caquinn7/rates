import gleam/list
import gleam/option.{Some}
import server/domain/currencies/currency_store.{type CurrencyStore}
import shared/currency.{Crypto, Fiat}

pub fn unable_to_create_twice_test() {
  use _ <- with_currency_store
  assert currency_store.new() == Error(Nil)
}

pub fn insert_inserts_currencies_test() {
  use store <- with_currency_store

  [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]
  |> currency_store.insert(store, _)

  let result = currency_store.get_all(store)

  assert list.length(result) == 2
  assert list.contains(result, Crypto(1, "Bitcoin", "BTC", Some(1)))
  assert list.contains(result, Fiat(2781, "United States Dollar", "USD", "$"))
}

pub fn insert_replaces_currency_when_id_already_exists_test() {
  use store <- with_currency_store

  let currency = Crypto(1, "Bitcoin", "BTC", Some(1))
  [currency]
  |> currency_store.insert(store, _)

  let updated_currency = Crypto(..currency, rank: Some(2))
  [updated_currency]
  |> currency_store.insert(store, _)

  assert currency_store.get_by_id(store, 1) == Ok(updated_currency)
}

/// Creates a new `CurrencyStore`, passes it to the given function, and ensures
/// the store is dropped afterward to avoid lingering state between tests.
///
/// This utility is intended for use in tests that require a fresh, isolated
/// `CurrencyStore` instance. It ensures proper cleanup regardless of what the
/// provided function does.
///
/// ## Example
/// ```gleam
/// with_currency_store(fn(store) {
///   currency_store.insert(store, [Crypto(1, "Bitcoin", "BTC", Some(1)])
///   // ... perform assertions ...
/// })
/// ```
fn with_currency_store(fun: fn(CurrencyStore) -> a) {
  let assert Ok(store) = currency_store.new()
  fun(store)
  currency_store.drop(store)
}
