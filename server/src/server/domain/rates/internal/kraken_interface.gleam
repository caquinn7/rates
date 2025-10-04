import server/domain/rates/internal/kraken_symbol.{type KrakenSymbol}
import server/integrations/kraken/client.{type KrakenClient}
import server/integrations/kraken/price_store.{type PriceEntry, type PriceStore}
import server/utils/retry

pub type KrakenInterface {
  KrakenInterface(
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
/// 
/// ## Returns
/// A fully configured KrakenInterface with default retry settings (5 retries, 50ms delay)
pub fn new(client: KrakenClient, price_store: PriceStore) -> KrakenInterface {
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

    retry.with_retry(get_price, 5, 50)
  }

  KrakenInterface(subscribe:, unsubscribe:, check_for_price:)
}
