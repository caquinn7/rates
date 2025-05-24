import gleam/bool
import gleam/dynamic/decode.{type Decoder}
import gleam/list

pub type KrakenResponse {
  InstrumentsResponse(List(InstrumentPair))
  TickerSubscribeConfirmation(String)
  TickerResponse(String, Float)
}

pub type InstrumentPair {
  InstrumentPair(symbol: String, base: String, quote: String)
}

pub fn decoder() -> Decoder(KrakenResponse) {
  decode.one_of(ticker_subscribe_confirmation_decoder(), or: [
    ticker_data_decoder(),
    instruments_decoder(),
  ])
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
  let failure_decoder =
    decode.failure(TickerSubscribeConfirmation(""), "KrakenResponse")

  use method <- decode.field("method", decode.string)
  use <- bool.guard(method != "subscribe", failure_decoder)

  use success <- decode.field("success", decode.bool)
  use <- bool.guard(!success, failure_decoder)

  use channel <- decode.subfield(["result", "channel"], decode.string)
  use <- bool.guard(channel != "ticker", failure_decoder)

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
    use last <- decode.field("last", decode.float)
    decode.success(TickerResponse(symbol, last))
  }

  use data <- decode.field("data", decode.list(ticker_decoder()))
  case list.first(data) {
    Error(_) -> decode.failure(TickerResponse("", -1.0), "KrakenResponse")
    Ok(ticker) -> decode.success(ticker)
  }
}
