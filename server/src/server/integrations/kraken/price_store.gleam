//// A simple in-memory store for tracking exchange rates received from Kraken.
////
//// The `PriceStore` module wraps a protected ETS (Erlang Term Storage) table for storing
//// the last inserted price of each currency pair supported by Kraken. It allows efficient
//// read access from any process, while write access is restricted to the owning process.
//// The process calling `new()` owns the table, which is destroyed when that process exits.
//// Access through a `PriceStore` requires the table to remain alive.

import gleam/result
import shared/numbers/positive_float.{type PositiveFloat}

/// Runtime identifier returned by `ets:new/2` for an unnamed ETS table.
type TableId

type PriceRow =
  #(String, PriceEntry)

/// A handle to a protected ETS table of prices and provider timestamps, keyed by
/// Kraken symbol. Any process may read from the store; only its owner may mutate it.
/// The handle becomes invalid when its owning process exits.
pub opaque type PriceStore {
  PriceStore(TableId)
}

/// A stored price and its timestamp in Unix milliseconds.
pub type PriceEntry {
  PriceEntry(price: PositiveFloat, timestamp: Int)
}

/// Creates an independent `PriceStore` backed by an unnamed, protected ETS table.
///
/// The calling process owns the table, which is destroyed when that process exits.
///
/// The table is configured as:
/// - **Protected**: Only the owner process can write; all processes can read.
/// - **Read-concurrent**: Multiple processes can read simultaneously, even during write operations.
/// - **Auto write concurrency**: The runtime automatically decides whether to enable write concurrency
///   optimizations based on actual usage patterns.
///
/// Pass the returned handle to processes that need to read from the table.
///
/// Returns an ETS diagnostic if table creation fails.
pub fn new() -> Result(PriceStore, String) {
  result.map(create_table(), PriceStore)
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
  let _ = insert_row(table, #(symbol, price_entry))
  Nil
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

  case lookup(table, symbol) {
    [] -> Error(Nil)
    [#(_, entry), ..] -> Ok(entry)
  }
}

/// Removes a price record from the store for the specified currency pair symbol.
///
/// Only the process that owns the store may call this.
/// If the symbol does not exist in the store, the operation succeeds silently
/// without any error.
pub fn delete_price(store: PriceStore, symbol: String) -> Nil {
  let PriceStore(table) = store
  let _ = delete_row(table, symbol)
  Nil
}

@external(erlang, "price_store_ffi", "create_table")
fn create_table() -> Result(TableId, String)

@external(erlang, "ets", "insert")
fn insert_row(table: TableId, row: PriceRow) -> Bool

@external(erlang, "ets", "lookup")
fn lookup(table: TableId, symbol: String) -> List(PriceRow)

@external(erlang, "ets", "delete")
fn delete_row(table: TableId, symbol: String) -> Bool
