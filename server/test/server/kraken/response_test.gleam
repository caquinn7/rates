import gleam/json
import gleam/list
import gleeunit/should
import server/kraken/response.{
  InstrumentPair, InstrumentsResponse, TickerResponse,
  TickerSubscribeConfirmation,
}

pub fn decode_ticker_subscribe_confirmation_test() {
  let json_str =
    "{\"method\":\"subscribe\",\"req_id\":69,\"result\":{\"channel\":\"ticker\",\"event_trigger\":\"trades\",\"snapshot\":true,\"symbol\":\"BTC/USD\"},\"success\":true,\"time_in\":\"2025-04-27T15:38:26.540456Z\",\"time_out\":\"2025-04-27T15:38:26.540489Z\"}"

  json_str
  |> json.parse(response.decoder())
  |> should.be_ok
  |> should.equal(TickerSubscribeConfirmation("BTC/USD"))
}

pub fn decode_ticker_unsubscribe_confirmation_should_not_be_mistaken_for_subscribe_confirmation_test() {
  let json_str =
    "{\"method\":\"unsubscribe\",\"req_id\":79,\"result\":{\"channel\":\"ticker\",\"event_trigger\":\"trades\",\"symbol\":\"BTC/USD\"},\"success\":true,\"time_in\":\"2025-05-08T00:56:06.967184Z\",\"time_out\":\"2025-05-08T00:56:06.967223Z\"}"

  json_str
  |> json.parse(response.decoder())
  |> should.be_error
}

pub fn decode_ticker_subscribe_confirmation_when_success_is_false_test() {
  let json_str =
    "{\"error\":\"Currency pair not supported xxx/USD\",\"method\":\"subscribe\",\"req_id\":69,\"success\":false,\"symbol\":\"xxx/USD\",\"time_in\":\"2025-04-27T15:37:48.652299Z\",\"time_out\":\"2025-04-27T15:37:48.652337Z\"}"

  json_str
  |> json.parse(response.decoder())
  |> should.be_error
}

pub fn decode_ticker_response_test() {
  let json_str =
    "{\"channel\":\"ticker\",\"type\":\"snapshot\",\"data\":[{\"symbol\":\"BTC/USD\",\"bid\":84393.0,\"bid_qty\":0.00915660,\"ask\":84393.1,\"ask_qty\":15.75854797,\"last\":84393.1,\"volume\":662.72278119,\"vwap\":84815.9,\"low\":84343.5,\"high\":85444.0,\"change\":-92.8,\"change_pct\":-0.11}]}"

  json_str
  |> json.parse(response.decoder())
  |> should.be_ok
  |> should.equal(TickerResponse("BTC/USD", 84_393.1))
}

pub fn decode_instrument_response_test() {
  let json_str =
    "{\"channel\":\"instrument\",\"type\":\"snapshot\",\"data\":{\"assets\":[{\"id\":\"USD\",\"status\":\"enabled\",\"precision\":4,\"precision_display\":2,\"borrowable\":true,\"collateral_value\":1.00,\"margin_rate\":0.050000}],\"pairs\":[{\"symbol\":\"BTC/USD\",\"base\":\"BTC\",\"quote\":\"USD\",\"status\":\"online\",\"qty_precision\":8,\"qty_increment\":0.00000001,\"price_precision\":1,\"cost_precision\":5,\"marginable\":true,\"has_index\":true,\"cost_min\":0.50,\"margin_initial\":0.20,\"position_limit_long\":300,\"position_limit_short\":240,\"tick_size\":0.1,\"price_increment\":0.1,\"qty_min\":0.00005000}]}}"

  let response =
    json_str
    |> json.parse(response.decoder())
    |> should.be_ok

  let assert InstrumentsResponse(pairs) = response

  pairs
  |> list.first
  |> should.be_ok
  |> should.equal(InstrumentPair("BTC/USD", "BTC", "USD"))
}
