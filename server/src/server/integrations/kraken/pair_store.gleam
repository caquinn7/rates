//// Stores supported Kraken symbols in a protected ETS table. The session owns
//// the table and updates it from instrument data. Other processes can read
//// directly through the handle while that session is alive.

import gleam/result
import gleam/set.{type Set}

/// Runtime identifier returned by `ets:new/2` for an unnamed ETS table.
type TableId

/// Handle to a session's protected ETS table of supported Kraken symbols.
pub opaque type PairStore {
  PairStore(TableId)
}

/// Creates an independent `PairStore` backed by an unnamed, protected ETS table.
///
/// The calling process owns the table, which is destroyed when that process exits.
///
/// The table has these access and concurrency settings.
/// - **Protected** access allows any process to read. Only the owner can write.
/// - **Read-concurrent** access optimizes simultaneous reads.
///
/// Pass the returned handle to processes that need to read from the table.
pub fn new() -> Result(PairStore, Nil) {
  result.map(create_table(), PairStore)
}

/// Publishes additions before deleting removed symbols so a nonempty registry
/// stays nonempty when one set of symbols replaces another.
pub fn apply_changes(
  store: PairStore,
  added added: Set(String),
  removed removed: Set(String),
) -> Nil {
  let PairStore(table) = store
  let rows = set.fold(added, [], fn(rows, symbol) { [#(symbol), ..rows] })
  let _ = insert_rows(table, rows)

  set.fold(removed, Nil, fn(_, symbol) {
    let _ = delete_row(table, symbol)
    Nil
  })
}

pub fn exists(store: PairStore, symbol: String) -> Bool {
  let PairStore(table) = store
  member(table, symbol)
}

pub fn count(store: PairStore) -> Int {
  let PairStore(table) = store
  size(table)
}

@external(erlang, "kraken_pairs_ffi", "create_table")
fn create_table() -> Result(TableId, Nil)

@external(erlang, "ets", "insert")
fn insert_rows(table: TableId, rows: List(#(String))) -> Bool

@external(erlang, "ets", "delete")
fn delete_row(table: TableId, symbol: String) -> Bool

/// Checks whether the table contains a row keyed by `symbol`.
@external(erlang, "ets", "member")
fn member(table: TableId, symbol: String) -> Bool

/// Returns the number of rows in the table. The adapter raises `badarg` if the
/// table ID has expired.
@external(erlang, "kraken_pairs_ffi", "size")
fn size(table: TableId) -> Int
