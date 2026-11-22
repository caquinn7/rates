//// An actor responsible for managing a live WebSocket connection to the Kraken
//// exchange and distributing real-time price updates to interested processes.
////
//// This module handles:
//// - Connecting to Kraken's WebSocket v2 API
//// - Subscribing to and unsubscribing from ticker channels
//// - Tracking which symbols are actively subscribed and by how many clients
//// - Writing the latest prices to the session's `PriceStore`
//// - Keeping the session's supported pairs current
////
//// Callers can read cached prices and supported pairs directly through the
//// client. The session requests an instrument snapshot on each connection and
//// stays subscribed to apply pair changes as they arrive.
////
//// Use `new` to create the actor and start the WebSocket session. Use
//// `subscribe` and `unsubscribe` to manage interest in specific symbols.
////
//// Initial handshake failures are returned to the caller. After startup, socket
//// failures reconnect automatically and restore remaining subscription interest.
//// Cached prices retain their original timestamps until fresh data arrives
//// or discovery and instrument updates remove the pair.

import gleam/otp/actor.{type StartError}
import gleam/result
import server/integrations/kraken/internal/session.{type SessionHandle}
import server/integrations/kraken/pair_store
import server/integrations/kraken/price_store.{type PriceEntry, type PriceStore}
import server/utils/logger.{type Logger}

/// Handle to a live Kraken session and its price and pair tables. A socket
/// reconnect preserves the handle. The session's exit invalidates both tables.
pub opaque type KrakenClient {
  KrakenClient(SessionHandle)
}

/// Creates a client connected to Kraken's public WebSocket v2 endpoint.
/// Waits for the initial handshake and returns an error if startup fails.
/// Calls `create_price_store` in the session process after the handshake;
/// instrument discovery continues asynchronously. Later connection failures
/// reconnect automatically while preserving interest and prices for listed pairs.
pub fn new(
  logger: Logger,
  create_price_store: fn() -> PriceStore,
) -> Result(KrakenClient, StartError) {
  new_with_url(logger, create_price_store, "https://ws.kraken.com/v2")
}

/// Creates a client using an alternative WebSocket endpoint, primarily for
/// integration tests that use a local server in place of Kraken. Application
/// code should normally use `new`.
///
/// Initial handshake failures return an error; subsequent failures reconnect.
pub fn new_with_url(
  logger: Logger,
  create_price_store: fn() -> PriceStore,
  websocket_url: String,
) -> Result(KrakenClient, StartError) {
  session.start(
    logger,
    create_price_store,
    websocket_url,
    session.default_config(),
  )
  |> result.map(fn(started) { KrakenClient(started.data) })
}

/// Reads the latest cached price and its provider timestamp for a symbol.
pub fn get_price(
  client: KrakenClient,
  symbol: String,
) -> Result(PriceEntry, Nil) {
  let KrakenClient(handle) = client
  price_store.get_price(handle.price_store, symbol)
}

/// Checks membership in this session's latest published instrument data.
pub fn supports_symbol(client: KrakenClient, symbol: String) -> Bool {
  let KrakenClient(handle) = client
  pair_store.exists(handle.pair_store, symbol)
}

/// Checks whether this session currently has at least one eligible symbol.
pub fn has_supported_pairs(client: KrakenClient) -> Bool {
  let KrakenClient(handle) = client
  pair_store.count(handle.pair_store) > 0
}

/// Adds one client's interest in a symbol, including while disconnected or
/// discovering instruments. Interested clients share one upstream subscription
/// while the session is ready and the symbol is eligible.
/// The request is handled asynchronously.
pub fn subscribe(client: KrakenClient, symbol: String) -> Nil {
  let KrakenClient(handle) = client
  actor.send(handle.subject, session.Subscribe(symbol))
}

/// Removes one client's interest in a symbol, including while disconnected.
/// Sends an upstream unsubscribe when the last reference to a requested ticker
/// is removed. The request is handled asynchronously.
pub fn unsubscribe(client: KrakenClient, symbol: String) -> Nil {
  let KrakenClient(handle) = client
  actor.send(handle.subject, session.Unsubscribe(symbol))
}
