import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/result
import server/kraken/price_store.{type PriceStore}
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

/// Attempts to fetch the latest price for a given `KrakenSymbol` from the shared `PriceStore`.
/// If the symbol is reversed, returns the inverse of the price.
/// Retries the lookup up to `retries` times, sleeping `delay` ms between attempts.
pub fn wait_for_kraken_price(
  kraken_symbol: KrakenSymbol,
  price_store: PriceStore,
  retries: Int,
  delay: Int,
) -> Result(Float, Nil) {
  let symbol_str = kraken_symbol.to_string(kraken_symbol)
  let symbol_dir = kraken_symbol.direction(kraken_symbol)

  case price_store.get_price(price_store, symbol_str) {
    Ok(price) -> {
      Ok(case symbol_dir {
        DirectSymbol -> price
        ReversedSymbol -> 1.0 /. price
      })
    }

    Error(_) if retries == 0 -> Error(Nil)

    _ -> {
      process.sleep(delay)
      wait_for_kraken_price(kraken_symbol, price_store, retries - 1, delay)
    }
  }
}
