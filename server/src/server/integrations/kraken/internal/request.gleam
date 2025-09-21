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
  let KrakenRequest(method, params, req_id) = kraken_req

  case req_id {
    None ->
      json.object([
        #("method", encode_method(method)),
        #("params", encode_params(params)),
      ])

    Some(i) ->
      json.object([
        #("method", encode_method(method)),
        #("params", encode_params(params)),
        #("req_id", json.int(i)),
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
