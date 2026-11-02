import gleam/bool
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/option.{type Option, None, Some}
import shared/positive_float.{type PositiveFloat}

/// Messages decoded from Kraken's WebSocket API for instrument discovery,
/// subscription tracking, price updates, and keepalive.
pub type KrakenResponse {
  /// Trading pairs from an instrument snapshot, used to populate the registry
  /// of supported symbols and enable ticker subscriptions.
  InstrumentsResponse(List(InstrumentPair))

  /// Acknowledges a successful ticker subscription for the given symbol.
  TickerSubscribeConfirmation(String)

  /// A symbol and its positive last traded price. The decoder uses the first
  /// data entry in the message; the session assigns a timestamp when storing it.
  TickerResponse(String, PositiveFloat)

  /// Reply to a Kraken JSON ping, carrying its request ID so the session can
  /// match the outstanding ping and clear its pong deadline.
  Pong(req_id: Int)
}

/// Trading pair listed in a Kraken instrument snapshot, such as `BTC/USD`.
pub type InstrumentPair {
  InstrumentPair(
    /// Kraken's subscription symbol for the pair, such as `BTC/USD`.
    symbol: String,
    /// Asset being priced, such as `BTC`.
    base: String,
    /// Asset the price is expressed in, such as `USD`.
    quote: String,
  )
}

/// Selects a response decoder using the message's method, channel, and type.
/// Returns `None` for message kinds the session does not consume, including
/// heartbeats, status messages, unsubscribe confirmations, and instrument updates.
/// Supported messages with invalid fields retain their specific decoding errors.
pub fn decoder() -> Decoder(Option(KrakenResponse)) {
  use method <- decode.optional_field("method", "", decode.string)

  case method {
    "pong" -> decode.map(pong_decoder(), Some)

    "subscribe" -> {
      use channel <- decode.subfield(["result", "channel"], decode.string)
      case channel {
        "ticker" -> decode.map(ticker_subscribe_confirmation_decoder(), Some)
        _ -> decode.success(None)
      }
    }

    "" -> channel_decoder()

    _ -> decode.success(None)
  }
}

fn channel_decoder() {
  use channel <- decode.optional_field("channel", "", decode.string)

  case channel {
    "instrument" | "ticker" -> {
      use kind <- decode.field("type", decode.string)
      case channel, kind {
        "instrument", "snapshot" -> decode.map(instruments_decoder(), Some)
        "ticker", "snapshot" | "ticker", "update" ->
          decode.map(ticker_data_decoder(), Some)
        _, _ -> decode.success(None)
      }
    }

    _ -> decode.success(None)
  }
}

fn instruments_decoder() {
  // {
  //     "channel": "instrument",
  //     "type": "snapshot",
  //     "data": {
  //         "assets": [
  //             {
  //                 "id": "USD",
  //                 "status": "enabled",
  //                 "precision": 4,
  //                 "precision_display": 2,
  //                 "borrowable": true,
  //                 "collateral_value": 1.00,
  //                 "margin_rate": 0.050000
  //             }
  //         ],
  //         "pairs": [
  //             {
  //                 "symbol": "BTC/USD",
  //                 "base": "BTC",
  //                 "quote": "USD",
  //                 "status": "online",
  //                 "qty_precision": 8,
  //                 "qty_increment": 0.00000001,
  //                 "price_precision": 1,
  //                 "cost_precision": 5,
  //                 "marginable": true,
  //                 "has_index": true,
  //                 "cost_min": 0.50,
  //                 "margin_initial": 0.20,
  //                 "position_limit_long": 300,
  //                 "position_limit_short": 240,
  //                 "tick_size": 0.1,
  //                 "price_increment": 0.1,
  //                 "qty_min": 0.00005000
  //             }
  //         ]
  //     }
  // }

  let pair_decoder = fn() {
    use symbol <- decode.field("symbol", decode.string)
    use base <- decode.field("base", decode.string)
    use quote <- decode.field("quote", decode.string)
    decode.success(InstrumentPair(symbol:, base:, quote:))
  }

  use pairs <- decode.subfield(["data", "pairs"], decode.list(pair_decoder()))
  decode.success(InstrumentsResponse(pairs))
}

fn pong_decoder() {
  use req_id <- decode.field("req_id", decode.int)
  decode.success(Pong(req_id))
}

fn ticker_subscribe_confirmation_decoder() {
  // {
  //     "method": "subscribe",
  //     "req_id": 69,
  //     "result": {
  //         "channel": "ticker",
  //         "event_trigger": "trades",
  //         "snapshot": true,
  //         "symbol": "BTC/USD"
  //     },
  //     "success": true,
  //     "time_in": "2025-04-27T15:38:26.540456Z",
  //     "time_out": "2025-04-27T15:38:26.540489Z"
  // }

  // {
  //     "error": "Currency pair not supported xxx/USD",
  //     "method": "subscribe",
  //     "req_id": 69,
  //     "success": false,
  //     "symbol": "xxx/USD",
  //     "time_in": "2025-04-27T15:37:48.652299Z",
  //     "time_out": "2025-04-27T15:37:48.652337Z"
  // }
  use success <- decode.field("success", decode.bool)
  use <- bool.guard(
    !success,
    decode.failure(
      TickerSubscribeConfirmation(""),
      "successful ticker subscription",
    ),
  )

  use symbol <- decode.subfield(["result", "symbol"], decode.string)
  decode.success(TickerSubscribeConfirmation(symbol))
}

fn ticker_data_decoder() {
  // {
  //     "channel": "ticker",
  //     "type": "update",
  //     "data": [
  //         {
  //             "symbol": "BTC/USD",
  //             "last": 84524.0,
  //         }
  //     ]
  // }
  let ticker_decoder = fn() {
    use symbol <- decode.field("symbol", decode.string)
    use last <- decode.field("last", positive_float.decoder())
    decode.success(TickerResponse(symbol, last))
  }

  use data <- decode.field("data", decode.list(ticker_decoder()))
  case list.first(data) {
    Error(_) ->
      decode.failure(
        TickerResponse("", positive_float.from_float_unsafe(1.0)),
        "TickerResponse",
      )
    Ok(ticker) -> decode.success(ticker)
  }
}
