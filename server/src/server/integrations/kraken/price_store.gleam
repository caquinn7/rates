//// A simple in-memory store for tracking exchange rates received from Kraken.
////
//// The `PriceStore` module wraps a protected ETS (Erlang Term Storage) table for storing
//// the last inserted price of each currency pair supported by Kraken. It allows efficient
//// read access from any process, while write access is restricted to the owning process.
//// The process calling `new()` owns the table, which is destroyed when that process exits.
//// Access through a `PriceStore` requires the table to remain alive.

import carpenter/table.{type Set as EtsSet, AutoWriteConcurrency, Protected}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/pair
import gleam/result
import shared/numbers/positive_float.{type PositiveFloat}

/// A handle to a protected ETS table of prices and provider timestamps, keyed by
/// Kraken symbol. Any process may read from the store; only its owner may mutate it.
/// The handle remains valid until the table is dropped or its owning process exits.
pub opaque type PriceStore {
  PriceStore(EtsSet(String, PriceEntry))
}

pub type PriceEntry {
  /// A stored price and its timestamp in Unix milliseconds.
  PriceEntry(price: PositiveFloat, timestamp: Int)
}

const table_name = "kraken_price_store"

/// Creates a new `PriceStore` by initializing a protected ETS table.
///
/// The calling process owns the table, which is destroyed when that process exits.
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

/// Inserts or replaces a price using the supplied Unix millisecond timestamp unchanged.
///
/// The last insertion replaces any existing entry for the symbol, even if its
/// timestamp is older. Timestamps are not compared or validated.
/// Only the process that owns the store may call this.
///
/// Example:
/// ```gleam
/// import server/integrations/kraken/price_store
/// import shared/numbers/positive_float
///
/// let assert Ok(store) = price_store.new()
/// let assert Ok(price) = positive_float.new(75_804.6)
/// // Provider quote time in Unix milliseconds.
/// let timestamp = 1_794_146_160_550
/// price_store.insert(store, "BTC/USD", price, timestamp)
/// ```
pub fn insert(
  store: PriceStore,
  symbol: String,
  price: PositiveFloat,
  timestamp: Int,
) -> Nil {
  let PriceStore(table) = store

  let price_entry = PriceEntry(price, timestamp)
  table.insert(table, [#(symbol, price_entry)])
}

/// Retrieves the last inserted price entry for a given symbol from the `PriceStore`.
///
/// Returns `Ok(PriceEntry(...))` if the symbol exists in the store, or `Error(Nil)`
/// if not found. No expiry or freshness check is applied to the stored timestamp.
///
/// Example:
/// ```gleam
/// import server/integrations/kraken/price_store.{PriceEntry}
/// import shared/numbers/positive_float
///
/// let assert Ok(store) = price_store.new()
/// let assert Ok(price) = positive_float.new(75_804.6)
/// let timestamp = 1_794_146_160_550
/// price_store.insert(store, "BTC/USD", price, timestamp)
///
/// let assert Ok(entry) = price_store.get_price(store, "BTC/USD")
/// assert entry == PriceEntry(price, timestamp)
/// assert price_store.get_price(store, "ETH/USD") == Error(Nil)
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
/// Only the process that owns the store may call this.
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
/// Returns `Error(Nil)` if the table does not currently exist, including after
/// deletion or owner exit. Checking availability does not keep the table alive;
/// subsequent operations still require a live table.
pub fn get_store() -> Result(PriceStore, Nil) {
  use name <- result.try(atom.get(table_name))

  case table_exists(name) {
    True ->
      table_name
      |> table.ref
      |> result.map(PriceStore)

    False -> Error(Nil)
  }
}

/// Deletes the underlying ETS table associated with the given `PriceStore`.
///
/// Only the process that owns the store may call this. Existing references must
/// not be used after deletion. The table is also destroyed when its owner exits.
pub fn drop(store: PriceStore) -> Nil {
  let PriceStore(table) = store
  table.drop(table)
}

@external(erlang, "price_store_ffi", "table_exists")
fn table_exists(table_name: Atom) -> Bool
