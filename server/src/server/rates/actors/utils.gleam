import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/result
import server/integrations/kraken/kraken.{type Kraken}
import server/integrations/kraken/price_store.{type PriceEntry, type PriceStore}
import server/rates/actors/kraken_symbol.{
  type KrakenSymbol, DirectSymbol, ReversedSymbol,
}
import shared/rates/rate_request.{type RateRequest}

/// Represents an error that occurred while resolving a currency ID to a symbol.
pub type SymbolResolutionError {
  CurrencyNotFound(Int)
}

/// Resolves the `from` and `to` currency IDs in a `RateRequest` to their string symbols
/// using the provided currency dictionary. Returns an error if either currency is not found.
pub fn resolve_currency_symbols(
  rate_request: RateRequest,
  currencies: Dict(Int, String),
) -> Result(#(String, String), SymbolResolutionError) {
  let try_get_symbol = fn(id) {
    currencies
    |> dict.get(id)
    |> result.replace_error(CurrencyNotFound(id))
  }

  use from_symbol <- result.try(try_get_symbol(rate_request.from))
  use to_symbol <- result.try(try_get_symbol(rate_request.to))
  Ok(#(from_symbol, to_symbol))
}

pub fn subscribe_to_kraken(kraken: Kraken, kraken_symbol: KrakenSymbol) -> Nil {
  let symbol_str = kraken_symbol.to_string(kraken_symbol)
  kraken.subscribe(kraken, symbol_str)
}

pub fn unsubscribe_from_kraken(
  kraken: Kraken,
  kraken_symbol: KrakenSymbol,
) -> Nil {
  let symbol_str = kraken_symbol.to_string(kraken_symbol)
  kraken.unsubscribe(kraken, symbol_str)
}

/// Attempts to fetch the latest price for a given `KrakenSymbol` from the shared `PriceStore`.
/// If the symbol is reversed, returns the inverse of the price.
/// Retries the lookup up to `retries` times, sleeping `delay` ms between attempts.
pub fn wait_for_kraken_price(
  kraken_symbol: KrakenSymbol,
  price_store: PriceStore,
  retries_left: Int,
  delay: Int,
) -> Result(PriceEntry, Nil) {
  let symbol_str = kraken_symbol.to_string(kraken_symbol)

  case price_store.get_price(price_store, symbol_str) {
    Ok(price_entry) -> Ok(price_entry)

    Error(_) if retries_left == 0 -> Error(Nil)

    Error(_) -> {
      process.sleep(delay)
      wait_for_kraken_price(kraken_symbol, price_store, retries_left - 1, delay)
    }
  }
}

/// Helper function to extract and transform price from a PriceEntry based on symbol direction
pub fn extract_price(
  price_entry: PriceEntry,
  kraken_symbol: KrakenSymbol,
) -> Float {
  let symbol_dir = kraken_symbol.direction(kraken_symbol)
  case symbol_dir {
    DirectSymbol -> price_entry.price
    ReversedSymbol -> 1.0 /. price_entry.price
  }
}
