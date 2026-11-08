import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import server/integrations/kraken/internal/response.{
  InstrumentPair, InstrumentsResponse, Pong, TickerResponse,
  TickerSubscribeConfirmation,
}

pub fn decode_correlated_pong_test() {
  "{\"method\":\"pong\",\"req_id\":42}"
  |> json.parse(response.decoder())
  |> should.equal(Ok(Some(Pong(42))))
}

pub fn decode_live_kraken_pong_without_success_field_test() {
  "{\"method\":\"pong\",\"req_id\":42,\"time_in\":\"2026-10-31T15:49:04.391605Z\",\"time_out\":\"2026-10-31T15:49:04.391618Z\"}"
  |> json.parse(response.decoder())
  |> should.equal(Ok(Some(Pong(42))))
}

pub fn malformed_or_uncorrelated_pongs_are_not_liveness_confirmations_test() {
  list.each(
    [
      "{\"method\":\"pong\"}",
      "{\"method\":\"pong\",\"req_id\":\"42\"}",
      "{\"method\":\"subscribe\",\"req_id\":42}",
    ],
    fn(text) {
      text |> json.parse(response.decoder()) |> should.be_error
      Nil
    },
  )
}

pub fn instrument_update_is_not_a_startup_snapshot_test() {
  "{\"channel\":\"instrument\",\"type\":\"update\",\"data\":{\"pairs\":[]}}"
  |> json.parse(response.decoder())
  |> should.equal(Ok(None))
}

import shared/numbers/positive_float

pub fn decode_ticker_subscribe_confirmation_test() {
  let json_str =
    "{\"method\":\"subscribe\",\"req_id\":69,\"result\":{\"channel\":\"ticker\",\"event_trigger\":\"trades\",\"snapshot\":true,\"symbol\":\"BTC/USD\"},\"success\":true,\"time_in\":\"2025-04-27T15:38:26.540456Z\",\"time_out\":\"2025-04-27T15:38:26.540489Z\"}"

  json_str
  |> json.parse(response.decoder())
  |> should.be_ok
  |> should.equal(Some(TickerSubscribeConfirmation("BTC/USD")))
}

pub fn decode_ticker_unsubscribe_confirmation_should_not_be_mistaken_for_subscribe_confirmation_test() {
  let json_str =
    "{\"method\":\"unsubscribe\",\"req_id\":79,\"result\":{\"channel\":\"ticker\",\"event_trigger\":\"trades\",\"symbol\":\"BTC/USD\"},\"success\":true,\"time_in\":\"2025-05-08T00:56:06.967184Z\",\"time_out\":\"2025-05-08T00:56:06.967223Z\"}"

  json_str
  |> json.parse(response.decoder())
  |> should.equal(Ok(None))
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
    "{\"channel\":\"ticker\",\"type\":\"snapshot\",\"data\":[{\"symbol\":\"BTC/USD\",\"bid\":84393.0,\"bid_qty\":0.00915660,\"ask\":84393.1,\"ask_qty\":15.75854797,\"last\":84393.1,\"volume\":662.72278119,\"vwap\":84815.9,\"low\":84343.5,\"high\":85444.0,\"change\":-92.8,\"change_pct\":-0.11,\"timestamp\":\"2026-11-08T13:56:00.550875Z\"}]}"

  json_str
  |> json.parse(response.decoder())
  |> should.be_ok
  |> should.equal(
    Some(TickerResponse(
      "BTC/USD",
      positive_float.from_float_unsafe(84_393.1),
      1_794_146_160_550,
    )),
  )
}

pub fn decode_instrument_response_test() {
  let json_str =
    "{\"channel\":\"instrument\",\"type\":\"snapshot\",\"data\":{\"assets\":[{\"id\":\"USD\",\"status\":\"enabled\",\"precision\":4,\"precision_display\":2,\"borrowable\":true,\"collateral_value\":1.00,\"margin_rate\":0.050000}],\"pairs\":[{\"symbol\":\"BTC/USD\",\"base\":\"BTC\",\"quote\":\"USD\",\"status\":\"online\",\"qty_precision\":8,\"qty_increment\":0.00000001,\"price_precision\":1,\"cost_precision\":5,\"marginable\":true,\"has_index\":true,\"cost_min\":0.50,\"margin_initial\":0.20,\"position_limit_long\":300,\"position_limit_short\":240,\"tick_size\":0.1,\"price_increment\":0.1,\"qty_min\":0.00005000}]}}"

  let response =
    json_str
    |> json.parse(response.decoder())
    |> should.be_ok

  let assert Some(InstrumentsResponse(pairs)) = response

  pairs
  |> list.first
  |> should.be_ok
  |> should.equal(InstrumentPair("BTC/USD", "BTC", "USD"))
}

pub fn malformed_responses_preserve_the_selected_decoders_field_errors_test() {
  list.each(
    [
      #("{\"method\":\"pong\",\"req_id\":\"42\"}", ["req_id"]),
      #(
        "{\"channel\":\"ticker\",\"type\":\"update\",\"data\":[{\"symbol\":\"BTC/USD\",\"last\":\"invalid\"}]}",
        ["data", "0", "last"],
      ),
      #(
        "{\"channel\":\"instrument\",\"type\":\"snapshot\",\"data\":{\"pairs\":[{\"symbol\":\"BTC/USD\",\"base\":42,\"quote\":\"USD\"}]}}",
        ["data", "pairs", "0", "base"],
      ),
      #(
        "{\"method\":\"subscribe\",\"success\":true,\"result\":{\"channel\":\"ticker\",\"symbol\":42}}",
        ["result", "symbol"],
      ),
      #("{\"channel\":\"ticker\",\"type\":42}", ["type"]),
    ],
    fn(test_case) {
      let #(text, expected_path) = test_case
      let assert Error(json.UnableToDecode([error, ..])) =
        json.parse(text, response.decoder())

      assert error.path == expected_path
    },
  )
}

pub fn unhandled_message_kinds_are_ignored_without_decoding_their_payloads_test() {
  list.each(
    [
      "{\"channel\":\"heartbeat\"}",
      "{\"channel\":\"status\",\"type\":\"update\",\"data\":[{\"system\":\"online\"}]}",
      "{\"method\":\"subscribe\",\"success\":true,\"result\":{\"channel\":\"instrument\"}}",
      "{\"method\":\"future\",\"data\":[{\"symbol\":\"BTC/USD\",\"last\":100.0}]}",
      "{\"channel\":\"future\",\"type\":\"update\",\"data\":[{\"symbol\":\"BTC/USD\",\"last\":100.0}]}",
      "{\"channel\":\"ticker\",\"type\":\"future\"}",
    ],
    fn(text) {
      text
      |> json.parse(response.decoder())
      |> should.equal(Ok(None))
    },
  )
}

pub fn decode_ticker_update_test() {
  "{\"channel\":\"ticker\",\"type\":\"update\",\"data\":[{\"symbol\":\"BTC/USD\",\"bid\":75804.6,\"bid_qty\":0.81824116,\"ask\":75804.7,\"ask_qty\":0.00026802,\"last\":75804.6,\"volume\":716.13372226,\"vwap\":75743.9,\"low\":75467.1,\"high\":76096.2,\"change\":-34.1,\"change_pct\":-0.04,\"trades\":51786,\"timestamp\":\"2026-11-08T13:56:00.550875Z\"}]}"
  |> json.parse(response.decoder())
  |> should.equal(
    Ok(
      Some(TickerResponse(
        "BTC/USD",
        positive_float.from_float_unsafe(75_804.6),
        1_794_146_160_550,
      )),
    ),
  )
}

pub fn reject_missing_null_or_invalid_ticker_timestamps_test() {
  ["snapshot", "update"]
  |> list.each(fn(kind) {
    [
      "",
      ",\"timestamp\":null",
      ",\"timestamp\":123",
      ",\"timestamp\":\"invalid\"",
      ",\"timestamp\":\"2026-02-30T00:00:00Z\"",
    ]
    |> list.each(fn(timestamp_field) {
      let payload =
        "{\"channel\":\"ticker\",\"type\":\""
        <> kind
        <> "\",\"data\":[{\"symbol\":\"BTC/USD\",\"last\":100"
        <> timestamp_field
        <> "}]}"
      let assert Error(json.UnableToDecode([error, ..])) =
        json.parse(payload, response.decoder())
      assert error.path == ["data", "0", "timestamp"]
    })
  })
}
