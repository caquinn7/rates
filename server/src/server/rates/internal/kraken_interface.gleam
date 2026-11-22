import server/integrations/kraken/client.{type KrakenClient}
import server/integrations/kraken/price_store.{type PriceEntry}
import server/rates/internal/kraken_symbol.{type KrakenSymbol}
import server/utils/retry

/// Kraken operations used by rate subscribers to resolve pairs, manage subscription
/// interest, and retrieve prices with provider timestamps.
pub type KrakenInterface {
  KrakenInterface(
    /// Resolves verified CoinMarketCap IDs to a direct or reversed Kraken pair.
    /// Returns `Error(Nil)` if an asset or pair is unavailable.
    get_kraken_symbol: fn(#(Int, Int)) -> Result(KrakenSymbol, Nil),
    /// Asynchronously registers one subscriber's interest in the pair.
    subscribe: fn(KrakenSymbol) -> Nil,
    /// Asynchronously releases one subscriber's interest in the pair.
    /// Other subscribers may keep the upstream subscription active.
    unsubscribe: fn(KrakenSymbol) -> Nil,
    /// Reads the stored price and provider timestamp without applying inversion.
    /// Returns `Error(Nil)` if no price is available.
    check_for_price: fn(KrakenSymbol) -> Result(PriceEntry, Nil),
  )
}

/// Creates an interface backed by one Kraken session. Missing prices are retried
/// up to five times with a 50 ms delay between attempts.
pub fn new(client: KrakenClient) -> KrakenInterface {
  let get_kraken_symbol = kraken_symbol.new(_, client.supports_symbol(client, _))

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
      |> client.get_price(client, _)
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
