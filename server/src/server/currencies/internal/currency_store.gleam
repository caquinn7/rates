//// In-memory store for currency data using a public ETS table.
////
//// ## Ownership and concurrency
////
//// The process calling `new()` owns the table. The table is destroyed when that
//// process exits, so the owner must remain alive for as long as the store is used.
////
//// Public access allows any process to read and write directly, without routing
//// operations through the owner's mailbox. This supports both startup inserts
//// and subsequent writes from `currency_symbol_cache`.
////
//// The store holds currency data; `currency_symbol_cache` serializes cache checks
//// and fetching. The store itself does not coordinate cache misses or API calls.
//// Individual ETS operations are atomic. Inserting a currency replaces any
//// existing entry with the same currency ID.

import carpenter/table.{
  type Set as EtsSet, AutoWriteConcurrency, Public, Set as EtsSet, Table,
}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/pair
import gleam/result
import shared/currency.{type Currency}

pub opaque type CurrencyStore {
  CurrencyStore(EtsSet(Int, Currency))
}

/// Creates a new `CurrencyStore` by initializing an ETS table.
///
/// The calling process owns the table, which is destroyed when that process exits.
///
/// The table is configured as:
/// - **Public**: All processes can read and write to the table.
/// - **Read-concurrent**: Multiple processes can read simultaneously, even during write operations.
/// - **Auto write concurrency**: The runtime automatically decides whether to enable write concurrency
///   optimizations based on actual usage patterns.
///
/// Returns `Error(Nil)` if a table with this name already exists.
pub fn new() -> Result(CurrencyStore, Nil) {
  table.build("currencies_store")
  |> table.privacy(Public)
  |> table.write_concurrency(AutoWriteConcurrency)
  |> table.read_concurrency(True)
  |> table.set
  |> result.map(CurrencyStore)
}

/// Inserts or updates currencies in the store.
///
/// Each currency is keyed by its `id` field. If a currency with the same `id` 
/// already exists in the store, it will be replaced with the new currency data.
pub fn insert(store: CurrencyStore, currencies: List(Currency)) -> Nil {
  let CurrencyStore(set) = store

  currencies
  |> list.map(fn(currency) { #(currency.id, currency) })
  |> table.insert(set, _)
}

/// Returns all currencies in the store.
///
/// Scans the entire table and copies all entries into a list. The result has no
/// guaranteed order and is not guaranteed to be a consistent snapshot while other
/// processes are writing to the table.
pub fn get_all(store: CurrencyStore) -> List(Currency) {
  store
  |> get_table_name
  |> table_to_list
  |> list.map(pair.second)
}

/// Looks up a currency by its ID.
///
/// Returns `Ok(currency)` when found, or `Error(Nil)` if the ID is absent.
pub fn get_by_id(store: CurrencyStore, id: Int) -> Result(Currency, Nil) {
  let CurrencyStore(set) = store

  case table.lookup(set, id) {
    [] -> Error(Nil)
    [elem, ..] -> Ok(elem.1)
  }
}

/// Returns all currencies whose symbol exactly matches `symbol`, including case.
///
/// Returns `[]` when no currencies match. Scans the entire table. The result has no
/// guaranteed order and is not guaranteed to be a consistent snapshot while other
/// processes are writing to the table.
pub fn get_by_symbol(store: CurrencyStore, symbol: String) -> List(Currency) {
  store
  |> get_table_name
  |> match_by_symbol(symbol)
  |> list.map(pair.second)
}

/// Deletes the underlying ETS table associated with the given `CurrencyStore`.
///
/// All references to the deleted table become invalid. The table is also destroyed
/// automatically when its owner process exits.
pub fn drop(store: CurrencyStore) -> Nil {
  let CurrencyStore(set) = store
  table.drop(set)
}

fn get_table_name(store: CurrencyStore) -> Atom {
  let CurrencyStore(set) = store
  let EtsSet(table) = set
  let Table(name) = table
  name
}

@external(erlang, "ets", "tab2list")
fn table_to_list(table_name: Atom) -> List(#(k, v))

@external(erlang, "currency_store_ffi", "match_by_symbol")
fn match_by_symbol(table_name: Atom, symbol: String) -> List(#(Int, Currency))
