import gleam/list
import gleam/option.{Some}
import server/currencies/internal/currency_store.{type CurrencyStore}
import shared/currency.{Crypto, Fiat}

// new

pub fn unable_to_create_twice_test() {
  use _ <- with_currency_store
  assert currency_store.new() == Error(Nil)
}

// insert

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
  currency_store.insert(store, [currency])

  let updated_currency = Crypto(..currency, rank: Some(2))
  currency_store.insert(store, [updated_currency])

  assert currency_store.get_by_id(store, 1) == Ok(updated_currency)
}

// get_by_id

pub fn get_by_id_returns_currency_when_found_test() {
  use store <- with_currency_store

  let btc = Crypto(1, "Bitcoin", "BTC", Some(1))
  let usd = Fiat(2781, "United States Dollar", "USD", "$")

  currency_store.insert(store, [btc, usd])

  assert currency_store.get_by_id(store, 1) == Ok(btc)
  assert currency_store.get_by_id(store, 2781) == Ok(usd)
}

pub fn get_by_id_returns_error_when_not_found_test() {
  use store <- with_currency_store

  let btc = Crypto(1, "Bitcoin", "BTC", Some(1))
  currency_store.insert(store, [btc])

  assert currency_store.get_by_id(store, 999) == Error(Nil)
}

pub fn get_by_id_returns_error_on_empty_store_test() {
  use store <- with_currency_store

  assert currency_store.get_by_id(store, 1) == Error(Nil)
}

// get_by_symbol

pub fn get_by_symbol_returns_empty_list_when_not_found_test() {
  use store <- with_currency_store

  let btc = Crypto(1, "Bitcoin", "BTC", Some(1))
  currency_store.insert(store, [btc])

  let result = currency_store.get_by_symbol(store, "ETH")
  assert result == []
}

pub fn get_by_symbol_returns_multiple_currencies_with_same_symbol_test() {
  use store <- with_currency_store

  // Some tokens might share the same symbol
  let currency1 = Crypto(1, "Token One", "TKN", Some(1))
  let currency2 = Crypto(2, "Token Two", "TKN", Some(2))
  let currency3 = Crypto(3, "Other Token", "OTH", Some(3))

  currency_store.insert(store, [currency1, currency2, currency3])

  let result = currency_store.get_by_symbol(store, "TKN")
  assert list.length(result) == 2
  assert list.contains(result, currency1)
  assert list.contains(result, currency2)
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
