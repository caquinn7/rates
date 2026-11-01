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

pub type KrakenRequest {
  KrakenRequest(method: Method, params: Params, req_id: Option(Int))
  Ping(req_id: Int)
}

pub type Method {
  Subscribe
  Unsubscribe
}

pub type Params {
  // Represents a message with "channel": "instrument"
  Instruments
  // Represents a message with "channel": "ticker" and a list of symbols.
  Tickers(List(String))
}

pub fn encode(kraken_req: KrakenRequest) -> Json {
  case kraken_req {
    Ping(req_id) ->
      json.object([
        #("method", json.string("ping")),
        #("req_id", json.int(req_id)),
      ])

    KrakenRequest(method, params, req_id) ->
      encode_subscription(method, params, req_id)
  }
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

pub fn encode_method(method: Method) -> Json {
  case method {
    Subscribe -> json.string("subscribe")
    Unsubscribe -> json.string("unsubscribe")
  }
}

pub fn encode_params(params: Params) -> Json {
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
