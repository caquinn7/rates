/// Stores and manages the set of Kraken-supported currency pairs in global persistent memory.
///
/// This module provides a lightweight interface around `persistent_term` to cache the full set
/// of Kraken symbols at application startup. Reads are fast and safe from any process, while writes
/// should be limited to a single owner (e.g. the Kraken actor) to avoid inconsistency.
import gleam/erlang/atom
import gleam/set.{type Set}

const key = "kraken_pairs"

/// Stores the full set of Kraken-supported currency pairs in persistent memory.
///
/// Example:
/// ```gleam
/// import gleam/set
///
/// let symbols = set.from_list(["BTC/USD", "ETH/USD", "ADA/BTC"])
/// pairs.set(symbols)
/// ```
pub fn set(symbols: Set(String)) -> Nil {
  put(key, symbols)
  Nil
}

/// Checks whether the given symbol exists in the stored Kraken symbol set.
///
/// Returns `True` if the symbol is supported by Kraken, or `False` if not or if
/// the set has not yet been initialized.
///
/// Example:
/// ```gleam
/// let is_supported = pairs.exists("BTC/USD")
/// ```
pub fn exists(symbol: String) -> Bool {
  key
  |> get(set.new())
  |> set.contains(symbol)
}

/// Returns the total number of symbols stored in persistent memory.
pub fn count() -> Int {
  key
  |> get(set.new())
  |> set.size
}

/// Removes the stored Kraken symbol set from persistent memory.
pub fn clear() -> Nil {
  erase(key)
  Nil
}

@external(erlang, "persistent_term", "put")
fn put(key: String, value: Set(String)) -> atom.Atom

@external(erlang, "persistent_term", "get")
fn get(key: String, default: Set(String)) -> Set(String)

@external(erlang, "persistent_term", "erase")
fn erase(key: String) -> Bool
