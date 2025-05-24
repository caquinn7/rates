import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/result
import server/kraken/pairs
import server/kraken/price_store.{type PriceStore}
import shared/rates/rate_request.{type RateRequest}

/// Represents a Kraken currency pair and whether it was found in the direct or reversed form.
/// For example, `Direct("BTC/USD")` vs `Reversed("USD/BTC")`.
pub opaque type KrakenSymbol {
  Direct(symbol: String)
  Reversed(symbol: String)
}

pub type SymbolDirection {
  SymbolDirect
  SymbolReversed
}

/// Retrieves the raw Kraken symbol string (e.g. "BTC/USD") from a `KrakenSymbol`.
pub fn unwrap_kraken_symbol(kraken_symbol: KrakenSymbol) -> String {
  kraken_symbol.symbol
}

/// Represents an error that occurred while resolving a currency ID to a symbol.
pub fn unwrap_kraken_symbol_direction(
  kraken_symbol: KrakenSymbol,
) -> SymbolDirection {
  case kraken_symbol {
    Direct(_) -> SymbolDirect
    Reversed(_) -> SymbolReversed
  }
}

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
  use from_symbol <- result.try(
    currencies
    |> dict.get(rate_request.from)
    |> result.replace_error(CurrencyNotFound(rate_request.from)),
  )
  use to_symbol <- result.try(
    currencies
    |> dict.get(rate_request.to)
    |> result.replace_error(CurrencyNotFound(rate_request.to)),
  )
  Ok(#(from_symbol, to_symbol))
}

/// Attempts to resolve a Kraken-compatible symbol from the given currency pair symbols.
/// Returns a `KrakenSymbol` indicating whether the direct or reversed form was matched.
/// Returns an error if neither form exists in the Kraken pair list.
pub fn resolve_kraken_symbol(
  currency_symbols: #(String, String),
) -> Result(KrakenSymbol, Nil) {
  let #(from_symbol, to_symbol) = currency_symbols

  let user_facing_symbol = from_symbol <> "/" <> to_symbol
  let reverse_symbol = to_symbol <> "/" <> from_symbol

  case pairs.exists(user_facing_symbol), pairs.exists(reverse_symbol) {
    True, _ -> Ok(Direct(user_facing_symbol))
    False, True -> Ok(Reversed(reverse_symbol))
    _, _ -> Error(Nil)
  }
}

/// Attempts to fetch the latest price for a given `KrakenSymbol` from the shared `PriceStore`.
/// If the symbol is reversed, returns the inverse of the price.
/// Retries the lookup up to `retries` times, sleeping `delay` ms between attempts.
pub fn wait_for_kraken_price(
  kraken_symbol: KrakenSymbol,
  price_store: PriceStore,
  retries: Int,
  delay: Int,
) -> Result(Float, Nil) {
  case price_store.get_price(price_store, kraken_symbol.symbol) {
    Ok(price) -> {
      case kraken_symbol {
        Direct(..) -> price
        Reversed(..) -> 1.0 /. price
      }
      |> Ok
    }

    Error(_) if retries == 0 -> Error(Nil)

    _ -> {
      process.sleep(delay)
      wait_for_kraken_price(kraken_symbol, price_store, retries - 1, delay)
    }
  }
}
