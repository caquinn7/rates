//// In-memory store for currency data using a public ETS table.
////
//// ## Concurrency Design
////
//// The store uses a **Public** ETS table, allowing any process to read and write.
//// This is intentional to support cache-on-miss behavior from HTTP handlers without
//// requiring a single owner process.
////
//// **Concurrency implications:**
//// - Multiple processes can simultaneously insert currencies, leading to potential
////   duplicate API calls when the cache is cold (race condition on cache miss).
//// - Individual ETS operations are atomic, preventing data corruption.
//// - Last write wins if multiple processes insert the same currency ID.
////
//// This design trades occasional duplicate API calls for simpler architecture and
//// better availability (no single point of failure). For the currency use case,
//// where writes are infrequent and eventually consistent data is acceptable,
//// this tradeoff is reasonable.

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

pub fn get_all(store: CurrencyStore) -> List(Currency) {
  let CurrencyStore(set) = store
  let EtsSet(table) = set
  let Table(name) = table

  name
  |> table_to_list
  |> list.map(pair.second)
}

pub fn get_by_id(store: CurrencyStore, id: Int) -> Result(Currency, Nil) {
  let CurrencyStore(set) = store

  case table.lookup(set, id) {
    [] -> Error(Nil)
    [elem, ..] -> Ok(elem.1)
  }
}

pub fn get_by_symbol(store: CurrencyStore, symbol: String) -> List(Currency) {
  let CurrencyStore(set) = store
  let EtsSet(table) = set
  let Table(name) = table

  name
  |> match_by_symbol(symbol)
  |> list.map(pair.second)
}

/// Deletes the underlying ETS table associated with the given `CurrencyStore`.
pub fn drop(store: CurrencyStore) -> Nil {
  let CurrencyStore(set) = store
  table.drop(set)
}

@external(erlang, "ets", "tab2list")
fn table_to_list(table_name: Atom) -> List(#(k, v))

@external(erlang, "currency_store_ffi", "match_by_symbol")
fn match_by_symbol(table_name: Atom, symbol: String) -> List(#(Int, Currency))
