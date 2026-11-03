//// An actor responsible for managing a live WebSocket connection to the Kraken
//// exchange and distributing real-time price updates to interested processes.
////
//// This module handles:
//// - Connecting to Kraken's WebSocket v2 API
//// - Subscribing to and unsubscribing from ticker channels
//// - Tracking which symbols are actively subscribed and by how many clients
//// - Writing the latest prices to a shared `PriceStore`
//// - Populating the global `pairs` registry with the set of supported symbols
////
//// Price updates are stored in a shared `PriceStore`, which other parts of the
//// application can query independently. Supported trading pairs are also exposed
//// globally via the `pairs` module. The client requests an instrument snapshot
//// on each connection, including reconnects, to refresh this registry. After
//// receiving the snapshot, it sends an unsubscribe for the instrument channel.
////
//// Use `new` to create the actor and start the WebSocket session. Use
//// `subscribe` and `unsubscribe` to manage interest in specific symbols.
////
//// Initial handshake failures are returned to the caller. After startup, socket
//// failures reconnect automatically and restore remaining subscription interest.
//// Cached prices retain their original timestamps until fresh data arrives.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor.{type StartError}
import gleam/result
import server/integrations/kraken/internal/session
import server/integrations/kraken/price_store.{type PriceStore}
import server/utils/logger.{type Logger}

/// Handle to a Kraken session for registering and removing subscription interest.
pub opaque type KrakenClient {
  KrakenClient(Subject(session.Message))
}

/// Creates a client connected to Kraken's public WebSocket v2 endpoint.
/// Waits for the initial handshake and returns an error if startup fails.
/// Calls `create_price_store` in the session process after the handshake;
/// instrument discovery continues asynchronously. Later connection failures
/// reconnect automatically while preserving subscriptions and cached prices.
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

/// Adds one client's interest in a symbol, including while disconnected or
/// discovering instruments. Sends an upstream subscription only when ready and
/// the first reference is added; further references share that subscription.
/// Symbols excluded by the latest known instrument snapshot are ignored.
/// The request is handled asynchronously.
pub fn subscribe(client: KrakenClient, symbol: String) -> Nil {
  let KrakenClient(subject) = client
  actor.send(subject, session.Subscribe(symbol))
}

/// Removes one client's interest in a symbol, including while disconnected.
/// Sends an upstream unsubscribe only when ready and the last reference is
/// removed. Untracked symbols are ignored. The request is handled asynchronously.
pub fn unsubscribe(client: KrakenClient, symbol: String) -> Nil {
  let KrakenClient(subject) = client
  actor.send(subject, session.Unsubscribe(symbol))
}
