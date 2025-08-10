import gleam/json
import gleam/option.{Some}
import server/ws/websocket.{AddCurrencies, GetRate}
import shared/currency.{Crypto}
import shared/rates/rate_request.{RateRequest}

pub fn websocket_request_decoder_decodes_get_rate_test() {
  let result =
    "{\"from\":1,\"to\":2781}"
    |> json.parse(websocket.websocket_request_decoder())

  assert Ok(GetRate(RateRequest(from: 1, to: 2781))) == result
}

pub fn websocket_request_decoder_decodes_add_currencies_test() {
  let result =
    "[{\"type\":\"crypto\",\"id\":1,\"name\":\"Bitcoin\",\"symbol\":\"BTC\",\"rank\":1}]"
    |> json.parse(websocket.websocket_request_decoder())

  assert Ok(AddCurrencies([Crypto(1, "Bitcoin", "BTC", Some(1))])) == result
}
