import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}

// {
//     "method": "subscribe",
//     "params": {
//         "channel": "instrument"
//     },
//     "req_id": 79
// }

// {
//     "method": "subscribe",
//     "params": {
//         "channel": "ticker",
//         "symbol": [
//             "BTC/USD"
//         ]
//     }
// }

/// Requests sent to Kraken's WebSocket API for instrument discovery,
/// ticker subscriptions, and connection keepalive.
pub type KrakenRequest {
  /// Subscribes to or unsubscribes from the instrument or ticker channel.
  /// The optional request ID can be used to match Kraken's response.
  KrakenRequest(method: Method, params: Params, req_id: Option(Int))

  /// A JSON keepalive ping whose request ID is echoed in the pong response.
  Ping(req_id: Int)
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
/// Pings include their request ID; subscribe and unsubscribe requests include
/// `req_id` only when supplied.
pub fn encode(kraken_req: KrakenRequest) -> Json {
  case kraken_req {
    Ping(req_id) -> encode_ping(req_id)
    KrakenRequest(method, params, req_id) ->
      encode_subscription(method, params, req_id)
  }
}

fn encode_ping(req_id: Int) -> Json {
  json.object([
    #("method", json.string("ping")),
    #("req_id", json.int(req_id)),
  ])
}

fn encode_subscription(
  method: Method,
  params: Params,
  req_id: Option(Int),
) -> Json {
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
