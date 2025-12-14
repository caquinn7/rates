import carpenter/table.{
  type Set as EtsSet, NoWriteConcurrency, Public, Set as EtsSet, Table,
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
/// - **Read-concurrent**: Optimized for concurrent reads from multiple processes.
/// - **No write concurrency optimization**: Minimizes overhead for workloads with infrequent writes.
///
/// Individual ETS operations (`insert`, `lookup`, etc.) are atomic, but sequences of operations
/// (e.g., read-then-write) are not. Multiple processes can write concurrently, but without
/// transactional guarantees across multiple operations.
///
/// Returns `Error(Nil)` if a table with this name already exists.
pub fn new() -> Result(CurrencyStore, Nil) {
  table.build("currencies_store")
  |> table.privacy(Public)
  |> table.write_concurrency(NoWriteConcurrency)
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
  store
  |> get_all
  |> list.filter(fn(currency) { currency.symbol == symbol })
}

/// Deletes the underlying ETS table associated with the given `CurrencyStore`.
pub fn drop(store: CurrencyStore) -> Nil {
  let CurrencyStore(set) = store
  table.drop(set)
}

@external(erlang, "ets", "tab2list")
fn table_to_list(table_name: Atom) -> List(#(k, v))
