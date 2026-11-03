import gleam/json
import gleam/option.{None, Some}
import server/integrations/kraken/internal/request.{
  Instruments, KrakenRequest, Ping, Subscribe, Tickers, Unsubscribe,
}

pub fn encode_application_ping_without_subscription_params_test() {
  let encoded =
    Ping(42)
    |> request.encode
    |> json.to_string

  assert encoded == "{\"method\":\"ping\",\"req_id\":42}"
}

pub fn encode_subscribe_instruments_with_req_id_test() {
  let encoded =
    KrakenRequest(Subscribe, Instruments, Some(1))
    |> request.encode
    |> json.to_string

  let expected =
    "{\"method\":\"subscribe\","
    <> "\"params\":{\"channel\":\"instrument\",\"snapshot\":true},"
    <> "\"req_id\":1}"

  assert encoded == expected
}

pub fn encode_unsubscribe_instruments_with_no_req_id_test() {
  let encoded =
    KrakenRequest(Unsubscribe, Instruments, None)
    |> request.encode
    |> json.to_string

  let expected =
    "{\"method\":\"unsubscribe\","
    <> "\"params\":{\"channel\":\"instrument\",\"snapshot\":true}}"

  assert encoded == expected
}

pub fn encode_subscribe_tickers_test() {
  let encoded =
    KrakenRequest(Subscribe, Tickers(["BTC/USD"]), None)
    |> request.encode
    |> json.to_string

  let expected =
    "{\"method\":\"subscribe\","
    <> "\"params\":{\"channel\":\"ticker\",\"symbol\":[\"BTC/USD\"],\"snapshot\":true}}"

  assert encoded == expected
}
