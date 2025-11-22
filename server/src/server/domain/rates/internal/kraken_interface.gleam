import server/domain/rates/internal/kraken_symbol.{type KrakenSymbol}
import server/integrations/kraken/client.{type KrakenClient}
import server/integrations/kraken/price_store.{type PriceEntry, type PriceStore}
import server/utils/retry

pub type KrakenInterface {
  KrakenInterface(
    get_kraken_symbol: fn(#(String, String)) -> Result(KrakenSymbol, Nil),
    subscribe: fn(KrakenSymbol) -> Nil,
    unsubscribe: fn(KrakenSymbol) -> Nil,
    check_for_price: fn(KrakenSymbol) -> Result(PriceEntry, Nil),
  )
}

/// Creates a KrakenInterface from a Kraken client and price store
/// 
/// This factory function encapsulates the construction of the interface,
/// including symbol conversion logic and price waiting with default retry parameters.
/// 
/// ## Parameters
/// - `client`: The KrakenClient for subscribing/unsubscribing
/// - `price_store`: The PriceStore for checking prices
/// - `symbol_exists`: Function to check if a symbol exists in Kraken's supported pairs
/// 
/// ## Returns
/// A fully configured KrakenInterface with default retry settings (5 retries, 50ms delay)
pub fn new(
  client: KrakenClient,
  price_store: PriceStore,
  symbol_exists: fn(String) -> Bool,
) -> KrakenInterface {
  let get_kraken_symbol = kraken_symbol.new(_, symbol_exists)

  let subscribe = fn(kraken_symbol) {
    kraken_symbol
    |> kraken_symbol.to_string
    |> client.subscribe(client, _)
  }

  let unsubscribe = fn(kraken_symbol) {
    kraken_symbol
    |> kraken_symbol.to_string
    |> client.unsubscribe(client, _)
  }

  let check_for_price = fn(kraken_symbol) {
    let get_price = fn() {
      kraken_symbol
      |> kraken_symbol.to_string
      |> price_store.get_price(price_store, _)
    }

    retry.attempt(get_price, 5, 50)
  }

  KrakenInterface(
    get_kraken_symbol:,
    subscribe:,
    unsubscribe:,
    check_for_price:,
  )
}
