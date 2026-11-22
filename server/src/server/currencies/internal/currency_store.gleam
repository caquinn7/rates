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

import gleam/list
import gleam/result
import shared/currency.{type Currency}

/// Runtime identifier returned by `ets:new/2` for an unnamed ETS table.
type TableId

/// An ETS row containing the currency ID key, symbol, and full currency record.
type CurrencyRow =
  #(Int, String, Currency)

/// Handle to a public ETS table of currencies keyed by currency ID.
pub opaque type CurrencyStore {
  CurrencyStore(TableId)
}

/// Creates an independent `CurrencyStore` backed by an unnamed ETS table.
///
/// The calling process owns the table, which is destroyed when that process exits.
///
/// The table is configured as:
/// - **Public**: All processes can read and write to the table.
/// - **Read-concurrent**: Multiple processes can read simultaneously, even during write operations.
/// - **Auto write concurrency**: The runtime automatically decides whether to enable write concurrency
///   optimizations based on actual usage patterns.
pub fn new() -> Result(CurrencyStore, Nil) {
  result.map(create_table(), CurrencyStore)
}

/// Inserts or updates currencies in the store.
///
/// Each currency is keyed by its `id` field. If a currency with the same `id`
/// already exists in the store, it will be replaced with the new currency data.
pub fn insert(store: CurrencyStore, currencies: List(Currency)) -> Nil {
  let CurrencyStore(table) = store

  let rows =
    list.map(currencies, fn(currency) {
      #(currency.id, currency.symbol, currency)
    })
  let _ = insert_rows(table, rows)
  Nil
}

/// Returns all currencies in the store.
///
/// Scans the entire table and copies all entries into a list. The result has no
/// guaranteed order and is not guaranteed to be a consistent snapshot while other
/// processes are writing to the table.
pub fn get_all(store: CurrencyStore) -> List(Currency) {
  let CurrencyStore(table) = store
  list.map(table_to_list(table), fn(row) { row.2 })
}

/// Looks up a currency by its ID.
///
/// Returns `Ok(currency)` when found, or `Error(Nil)` if the ID is absent.
pub fn get_by_id(store: CurrencyStore, id: Int) -> Result(Currency, Nil) {
  let CurrencyStore(table) = store

  case lookup(table, id) {
    [] -> Error(Nil)
    [row, ..] -> Ok(row.2)
  }
}

/// Returns all currencies whose symbol exactly matches `symbol`, including case.
///
/// Returns `[]` when no currencies match. Scans the entire table. The result has no
/// guaranteed order and is not guaranteed to be a consistent snapshot while other
/// processes are writing to the table.
pub fn get_by_symbol(store: CurrencyStore, symbol: String) -> List(Currency) {
  let CurrencyStore(table) = store
  list.map(match_by_symbol(table, symbol), fn(row) { row.2 })
}

/// Deletes the underlying ETS table associated with the given `CurrencyStore`.
///
/// All references to the deleted table become invalid. The table is also destroyed
/// automatically when its owner process exits.
pub fn drop(store: CurrencyStore) -> Nil {
  let CurrencyStore(table) = store
  let _ = delete_table(table)
  Nil
}

@external(erlang, "currency_store_ffi", "create_table")
fn create_table() -> Result(TableId, Nil)

@external(erlang, "ets", "insert")
fn insert_rows(table: TableId, rows: List(CurrencyRow)) -> Bool

@external(erlang, "ets", "tab2list")
fn table_to_list(table: TableId) -> List(CurrencyRow)

@external(erlang, "ets", "lookup")
fn lookup(table: TableId, id: Int) -> List(CurrencyRow)

@external(erlang, "currency_store_ffi", "match_by_symbol")
fn match_by_symbol(table: TableId, symbol: String) -> List(CurrencyRow)

@external(erlang, "ets", "delete")
fn delete_table(table: TableId) -> Bool
