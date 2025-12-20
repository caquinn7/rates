//// A simple in-memory store for tracking exchange rates received from Kraken.
////
//// The `PriceStore` module wraps a protected ETS (Erlang Term Storage) table for storing
//// the most recent price of each currency pair supported by Kraken. It allows efficient
//// read access from any process, while write access is restricted to the owning process.

import carpenter/table.{type Set as EtsSet, AutoWriteConcurrency, Protected}
import gleam/list
import gleam/pair
import gleam/result
import server/utils/time

pub opaque type PriceStore {
  PriceStore(EtsSet(String, PriceEntry))
}

pub type PriceEntry {
  PriceEntry(price: Float, timestamp: Int)
}

const table_name = "kraken_price_store"

/// Creates a new `PriceStore` by initializing a protected ETS table.
///
/// The table is configured as:
/// - **Protected**: Only the owner process can write; all processes can read.
/// - **Read-concurrent**: Multiple processes can read simultaneously, even during write operations.
/// - **Auto write concurrency**: The runtime automatically decides whether to enable write concurrency
///   optimizations based on actual usage patterns.
///
/// This function is intended to be called once by the owner process during application startup.
/// Other processes should use `get_store` to access the table.
///
/// Returns `Error(Nil)` if a table with this name already exists.
pub fn new() -> Result(PriceStore, Nil) {
  table_name
  |> table.build
  |> table.privacy(Protected)
  |> table.write_concurrency(AutoWriteConcurrency)
  |> table.read_concurrency(True)
  |> table.set
  |> result.map(PriceStore)
}

/// Inserts or updates the latest price for a given symbol in the `PriceStore`.
///
/// If the symbol already exists in the store, its price is overwritten with the new value.
/// Only the process that owns the `PriceStore` (i.e. the one that called `new`) should call this.
///
/// Example:
/// ```gleam
/// let Ok(store) = price_store.new()
/// price_store.insert(store, "BTC/USD", 67350.25)
/// ```
pub fn insert(store: PriceStore, symbol: String, price: Float) -> Nil {
  insert_with_timestamp(store, symbol, price, time.system_time_ms())
}

pub fn insert_with_timestamp(
  store: PriceStore,
  symbol: String,
  price: Float,
  current_time_ms: Int,
) -> Nil {
  let PriceStore(table) = store

  let price_entry = PriceEntry(price, current_time_ms)
  table.insert(table, [#(symbol, price_entry)])
}

/// Retrieves the most recent price for a given symbol from the `PriceStore`.
///
/// Returns `Ok(price)` if the symbol exists in the store, or `Error(Nil)` if not found.
///
/// Example:
/// ```gleam
/// let assert Ok(store) = price_store.get_store()
/// let result = price_store.get_price(store, "BTC/USD")
/// ```
pub fn get_price(store: PriceStore, symbol: String) -> Result(PriceEntry, Nil) {
  let PriceStore(table) = store

  table
  |> table.lookup(symbol)
  |> list.first
  |> result.map(pair.second)
}

/// Removes a price record from the store for the specified currency pair symbol.
/// 
/// If the symbol does not exist in the store, the operation succeeds silently
/// without any error.
pub fn delete_price(store: PriceStore, symbol: String) -> Nil {
  let PriceStore(table) = store
  table.delete(table, symbol)
}

/// Returns a reference to an already-initialized `PriceStore`.
///
/// This is intended for use by processes that did not create the store themselves,
/// but need to read from it.
///
/// Returns an error if the store has not been initialized yet.
pub fn get_store() -> Result(PriceStore, Nil) {
  table_name
  |> table.ref
  |> result.map(PriceStore)
}

/// Deletes the underlying ETS table associated with the given `PriceStore`.
pub fn drop(store: PriceStore) -> Nil {
  let PriceStore(table) = store
  table.drop(table)
}
