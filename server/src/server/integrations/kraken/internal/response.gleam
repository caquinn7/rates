import gleam/bool
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/option.{type Option, None, Some}
import server/utils/time
import shared/numbers/positive_float.{type PositiveFloat}

/// Messages decoded from Kraken's WebSocket API for instrument discovery,
/// subscription tracking and price updates.
pub type KrakenResponse {
  /// Trading pairs from an instrument snapshot, used to populate the registry
  /// of supported symbols and enable ticker subscriptions.
  InstrumentSnapshot(List(InstrumentPair))

  /// Changes to individual pairs on the instrument channel.
  InstrumentUpdate(List(InstrumentPair))

  /// Acknowledges a successful ticker subscription for the symbol and request ID.
  TickerSubscribeConfirmation(symbol: String, req_id: Int)

  /// A symbol, its positive last traded price, and the provider's ticker timestamp
  /// in Unix milliseconds. The decoder uses the first data entry in the message.
  TickerResponse(symbol: String, price: PositiveFloat, timestamp: Int)
}

/// The instrument fields used to decide whether a pair is eligible for prices.
pub type InstrumentPair {
  InstrumentPair(
    /// Kraken's subscription symbol for the pair, such as `BTC/USD`.
    symbol: String,
    /// Kraken's trading status for the pair, such as `online` or `delisted`.
    status: String,
  )
}

/// Selects a response decoder using the message's method, channel, and type.
/// Returns `None` for message kinds the session does not consume, including
/// heartbeats, status messages, and unsubscribe confirmations.
/// Supported messages with invalid fields retain their specific decoding errors.
pub fn decoder() -> Decoder(Option(KrakenResponse)) {
  use method <- decode.optional_field("method", "", decode.string)

  case method {
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
      use type_ <- decode.field("type", decode.string)

      case channel, type_ {
        "instrument", "snapshot" ->
          decode.map(instrument_snapshot_decoder(), Some)

        "instrument", "update" -> decode.map(instrument_update_decoder(), Some)

        "ticker", "snapshot" | "ticker", "update" ->
          decode.map(ticker_data_decoder(), Some)

        _, _ -> decode.success(None)
      }
    }

    _ -> decode.success(None)
  }
}

fn instrument_snapshot_decoder() {
  use pairs <- decode.subfield(["data", "pairs"], decode.list(pair_decoder()))
  decode.success(InstrumentSnapshot(pairs))
}

fn instrument_update_decoder() {
  let data_decoder = {
    use pairs <- decode.optional_field("pairs", [], decode.list(pair_decoder()))
    decode.success(InstrumentUpdate(pairs))
  }

  use update <- decode.field("data", data_decoder)
  decode.success(update)
}

fn pair_decoder() {
  use symbol <- decode.field("symbol", decode.string)
  use status <- decode.field("status", decode.string)
  decode.success(InstrumentPair(symbol:, status:))
}

fn ticker_subscribe_confirmation_decoder() {
  use success <- decode.field("success", decode.bool)
  use <- bool.guard(
    !success,
    decode.failure(
      TickerSubscribeConfirmation("", 0),
      "successful ticker subscription",
    ),
  )

  use symbol <- decode.subfield(["result", "symbol"], decode.string)
  use req_id <- decode.field("req_id", decode.int)
  decode.success(TickerSubscribeConfirmation(symbol, req_id))
}

fn ticker_data_decoder() {
  let ticker_decoder = fn() {
    use symbol <- decode.field("symbol", decode.string)
    use last <- decode.field("last", positive_float.decoder())
    use timestamp <- decode.field("timestamp", time.rfc3339_ms_decoder())
    decode.success(TickerResponse(symbol, last, timestamp))
  }

  use data <- decode.field("data", decode.list(ticker_decoder()))
  case list.first(data) {
    Ok(ticker) -> decode.success(ticker)
    Error(_) ->
      decode.failure(
        TickerResponse("", positive_float.from_float_unsafe(1.0), 0),
        "TickerResponse",
      )
  }
}
