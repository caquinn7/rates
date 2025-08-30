/// A simple in-memory store for tracking exchange rates received from Kraken.
///
/// The `PriceStore` module wraps a protected ETS (Erlang Term Storage) table for storing
/// the most recent price of each currency pair supported by Kraken. It allows efficient
/// read access from any process, while write access is restricted to the owning process.
import carpenter/table.{type Set as EtsSet, NoWriteConcurrency, Protected}
import gleam/list
import gleam/pair
import gleam/result
import server/time

pub opaque type PriceStore {
  PriceStore(EtsSet(String, PriceEntry))
}

pub type PriceEntry {
  PriceEntry(Float, Int)
}

const table_name = "kraken_price_store"

/// Creates a new `PriceStore` by initializing a protected ETS table.
///
/// The table is:
/// - **Protected**: readable by all processes but writable only by the owner.
/// - **Read-concurrent**: allows multiple processes to read simultaneously.
/// - **Write-serialized**: disallows concurrent writes to ensure consistency.
///
/// This function is intended to be called once by the owner process during application startup.
/// Other processes should use `get_store` to access the table.
pub fn new() -> Result(PriceStore, Nil) {
  table_name
  |> table.build
  |> table.privacy(Protected)
  |> table.write_concurrency(NoWriteConcurrency)
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
pub fn insert(price_store: PriceStore, symbol: String, price: Float) -> Nil {
  insert_with_timestamp(price_store, symbol, price, time.current_time_ms())
}

pub fn insert_with_timestamp(price_store, symbol, price, current_time_ms) {
  let PriceStore(table) = price_store

  let price_entry = PriceEntry(price, current_time_ms)
  table.insert(table, [#(symbol, price_entry)])
}

/// Retrieves the most recent price for a given symbol from the `PriceStore`.
///
/// Returns `Ok(price)` if the symbol exists in the store, or `Error(Nil)` if not found.
///
/// Example:
/// ```gleam
/// let Ok(store) = price_store.get_store()
/// let result = price_store.get_price(store, "BTC/USD")
/// ```
pub fn get_price(
  price_store: PriceStore,
  symbol: String,
) -> Result(PriceEntry, Nil) {
  let PriceStore(table) = price_store

  table
  |> table.lookup(symbol)
  |> list.first
  |> result.map(pair.second)
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
pub fn drop(price_store: PriceStore) -> Nil {
  let PriceStore(table) = price_store
  table.drop(table)
}
