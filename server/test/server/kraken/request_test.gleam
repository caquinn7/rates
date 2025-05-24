import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should
import server/kraken/request.{
  Instruments, KrakenRequest, Subscribe, Tickers, Unsubscribe,
}

pub fn encode_method_subscribe_test() {
  Subscribe
  |> request.encode_method
  |> json.to_string
  |> should.equal("\"subscribe\"")
}

pub fn encode_method_unsubscribe_test() {
  Unsubscribe
  |> request.encode_method
  |> json.to_string
  |> should.equal("\"unsubscribe\"")
}

pub fn encode_params_instruments_test() {
  Instruments
  |> request.encode_params
  |> json.to_string
  |> should.equal("{\"channel\":\"instrument\",\"snapshot\":true}")
}

pub fn encode_params_tickers_test() {
  Tickers(["BTC/USD"])
  |> request.encode_params
  |> json.to_string
  |> should.equal(
    "{\"channel\":\"ticker\",\"symbol\":[\"BTC/USD\"],\"snapshot\":true}",
  )
}

pub fn encode_kraken_request_with_req_id_test() {
  let method = Subscribe
  let params = Instruments
  let req_id = 1

  KrakenRequest(method, params, Some(req_id))
  |> request.encode
  |> json.to_string
  |> should.equal(
    "{"
    <> "\"method\":"
    <> json.to_string(request.encode_method(method))
    <> ","
    <> "\"params\":"
    <> json.to_string(request.encode_params(params))
    <> ","
    <> "\"req_id\":"
    <> int.to_string(req_id)
    <> "}",
  )
}

pub fn encode_kraken_request_with_no_req_id_test() {
  let method = Subscribe
  let params = Instruments

  KrakenRequest(method, params, None)
  |> request.encode
  |> json.to_string
  |> should.equal(
    "{"
    <> "\"method\":"
    <> json.to_string(request.encode_method(method))
    <> ","
    <> "\"params\":"
    <> json.to_string(request.encode_params(params))
    <> "}",
  )
}
