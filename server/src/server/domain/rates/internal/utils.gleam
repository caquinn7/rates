import gleam/erlang/process
import server/domain/rates/internal/kraken_symbol.{type KrakenSymbol}
import server/integrations/kraken/price_store.{type PriceEntry, type PriceStore}

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
