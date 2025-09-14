import birdie
import gleam/json
import gleam/option.{Some}
import shared/currency.{Crypto}
import shared/rates/rate_request.{RateRequest}
import shared/subscriptions/subscription_id
import shared/subscriptions/subscription_request.{SubscriptionRequest}
import shared/websocket_request.{AddCurrencies, Subscribe, Unsubscribe, encode}

pub fn encode_subscribe_test() {
  let assert Ok(sub_id) = subscription_id.new("1")
  let subscription_request = SubscriptionRequest(sub_id, RateRequest(2, 3))

  Subscribe([subscription_request])
  |> encode
  |> json.to_string
  |> birdie.snap("encode_subscribe_test")
}

pub fn encode_unsubscribe_test() {
  let assert Ok(sub_id) = subscription_id.new("1")

  Unsubscribe(sub_id)
  |> encode
  |> json.to_string
  |> birdie.snap("encode_unsubscribe_test")
}

pub fn encode_add_currencies_test() {
  let crypto_currency = Crypto(22_354, "Quai Network", "QUAI", Some(3568))

  AddCurrencies([crypto_currency])
  |> encode
  |> json.to_string
  |> birdie.snap("encode_add_currencies_test")
}

pub fn decoder_decodes_subscribe_test() {
  let json =
    "{\"action\":\"subscribe\",\"body\":[{\"id\":\"1\",\"rate_request\":{\"from\":2,\"to\":3}}]}"

  let result = json.parse(json, websocket_request.decoder())

  let assert Ok(Subscribe([SubscriptionRequest(id, RateRequest(2, 3))])) =
    result

  assert "1" == subscription_id.to_string(id)
}

pub fn decoder_decodes_subscribe_when_body_is_empty_list_test() {
  let json = "{\"action\":\"subscribe\",\"body\":[]}"
  assert Ok(Subscribe([])) == json.parse(json, websocket_request.decoder())
}

pub fn decoder_decodes_unsubscribe_test() {
  let json = "{\"action\":\"unsubscribe\",\"body\":{\"id\":\"1\"}}"

  let result = json.parse(json, websocket_request.decoder())

  let assert Ok(Unsubscribe(id)) = result
  assert "1" == subscription_id.to_string(id)
}

pub fn decoder_decodes_add_currencies_test() {
  let json =
    "{\"action\":\"add_currencies\",\"body\":[{\"type\":\"crypto\",\"id\":22354,\"name\":\"Quai Network\",\"symbol\":\"QUAI\",\"rank\":3568}]}"

  assert Ok(AddCurrencies([Crypto(22_354, "Quai Network", "QUAI", Some(3568))]))
    == json.parse(json, websocket_request.decoder())
}

pub fn decoder_decodes_add_currencies_when_body_is_empty_list_test() {
  let json = "{\"action\":\"add_currencies\",\"body\":[]}"
  assert Ok(AddCurrencies([])) == json.parse(json, websocket_request.decoder())
}

pub fn decoder_returns_error_when_input_is_invalid_test() {
  let result = json.parse("", websocket_request.decoder())
  let assert Error(_) = result
}
