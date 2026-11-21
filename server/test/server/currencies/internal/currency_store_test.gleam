import exception
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import server/currencies/internal/currency_store.{type CurrencyStore}
import shared/currency.{Crypto, Fiat}

// new

pub fn stores_are_independent_across_owners_test() {
  use local_store <- with_currency_store

  // Create the second table in an unlinked process so the test can stop its owner.
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(store) = currency_store.new()
      process.send(ready, store)
      process.sleep_forever()
    })
  use <- exception.defer(fn() { process.kill(owner) })

  // Write different values under the same ID. The second write exercises public
  // access from outside the table's owning process, as the symbol cache does.
  let assert Ok(other_store) = process.receive(ready, 1000)
  let currency = Crypto(1, "Bitcoin", "BTC", Some(1))
  let other_currency = Crypto(..currency, rank: Some(2))
  currency_store.insert(local_store, [currency])
  currency_store.insert(other_store, [other_currency])

  assert currency_store.get_by_id(local_store, 1) == Ok(currency)
  assert currency_store.get_by_id(other_store, 1) == Ok(other_currency)

  // Wait for the owner to exit before checking that ETS cleaned up its table.
  let monitor = process.monitor(owner)
  process.kill(owner)
  let assert Ok(Nil) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)

  let assert Error(exception.Errored(reason)) =
    exception.rescue(fn() { currency_store.get_by_id(other_store, 1) })
  assert decode.run(reason, atom.decoder()) == Ok(atom.create("badarg"))
  assert currency_store.get_by_id(local_store, 1) == Ok(currency)
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

pub fn insert_replaces_symbol_without_affecting_other_currencies_test() {
  use store <- with_currency_store

  let currency = Crypto(1, "Token", "OLD", Some(1))
  let other_currency = Fiat(2781, "Other Currency", "OLD", "$")
  currency_store.insert(store, [currency, other_currency])

  let updated_currency = Crypto(..currency, symbol: "NEW")
  currency_store.insert(store, [updated_currency])

  assert currency_store.get_by_id(store, currency.id) == Ok(updated_currency)
  assert currency_store.get_by_symbol(store, "NEW") == [updated_currency]
  assert currency_store.get_by_symbol(store, "OLD") == [other_currency]
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

pub fn get_by_symbol_is_case_sensitive_test() {
  use store <- with_currency_store

  let btc = Crypto(1, "Bitcoin", "BTC", Some(1))
  currency_store.insert(store, [btc])

  assert currency_store.get_by_symbol(store, "BTC") == [btc]
  assert currency_store.get_by_symbol(store, "btc") == []
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

pub fn get_by_symbol_returns_crypto_and_fiat_with_same_symbol_test() {
  use store <- with_currency_store

  let crypto = Crypto(1, "Token", "USD", Some(1))
  let fiat = Fiat(2781, "United States Dollar", "USD", "$")
  let unrelated = Crypto(1027, "Ethereum", "ETH", Some(2))
  currency_store.insert(store, [crypto, fiat, unrelated])

  let result = currency_store.get_by_symbol(store, "USD")
  assert list.length(result) == 2
  assert list.contains(result, crypto)
  assert list.contains(result, fiat)
}

/// Runs a test callback with a fresh, unnamed `CurrencyStore` and drops the
/// store when the callback returns or raises.
fn with_currency_store(run: fn(CurrencyStore) -> a) -> a {
  let assert Ok(store) = currency_store.new()
  use <- exception.defer(fn() { currency_store.drop(store) })
  run(store)
}
