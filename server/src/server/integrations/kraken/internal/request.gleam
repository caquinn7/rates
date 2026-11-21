import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}

/// Requests sent to Kraken's WebSocket API for instrument discovery,
/// and ticker subscriptions.
pub type KrakenRequest {
  /// Subscribes to or unsubscribes from the instrument or ticker channel.
  /// The optional request ID can be used to match Kraken's response.
  KrakenRequest(method: Method, params: Params, req_id: Option(Int))
}

/// The subscription operation to perform for the channel and symbols in `Params`.
pub type Method {
  /// Starts receiving messages for the requested channel and symbols.
  Subscribe

  /// Stops receiving messages for the requested channel and symbols.
  Unsubscribe
}

/// The channel and symbols targeted by a subscribe or unsubscribe request.
pub type Params {
  /// The instrument channel, which provides trading pair metadata for
  /// discovering supported symbols.
  Instruments

  /// The ticker channel for the listed Kraken symbols, such as `BTC/USD`.
  Tickers(List(String))
}

/// Encodes a request as a JSON object for Kraken's WebSocket API.
/// Includes `req_id` when supplied.
pub fn encode(kraken_req: KrakenRequest) -> Json {
  let KrakenRequest(method:, params:, req_id:) = kraken_req
  case req_id {
    Some(i) ->
      json.object([
        #("method", encode_method(method)),
        #("params", encode_params(params)),
        #("req_id", json.int(i)),
      ])

    None ->
      json.object([
        #("method", encode_method(method)),
        #("params", encode_params(params)),
      ])
  }
}

fn encode_method(method: Method) -> Json {
  case method {
    Subscribe -> json.string("subscribe")
    Unsubscribe -> json.string("unsubscribe")
  }
}

fn encode_params(params: Params) -> Json {
  case params {
    Instruments ->
      json.object([
        #("channel", json.string("instrument")),
        #("snapshot", json.bool(True)),
      ])

    Tickers(symbols) ->
      json.object([
        #("channel", json.string("ticker")),
        #("symbol", json.array(symbols, json.string)),
        #("snapshot", json.bool(True)),
      ])
  }
}
