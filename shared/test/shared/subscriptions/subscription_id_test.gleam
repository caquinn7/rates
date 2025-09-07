import gleam/json
import shared/subscriptions/subscription_id

pub fn new_returns_ok_when_value_is_not_empty_test() {
  let assert Ok(_) = subscription_id.new("1")
}

pub fn new_returns_error_when_value_is_empty_string_test() {
  assert Error(Nil) == subscription_id.new("")
}

pub fn new_returns_error_when_value_is_whitespace_test() {
  assert Error(Nil) == subscription_id.new(" ")
}

pub fn to_string_returns_inner_value_test() {
  let assert Ok(sub_id) = subscription_id.new("1")
  assert "1" == subscription_id.to_string(sub_id)
}

pub fn decoder_decodes_subscription_id_when_value_is_valid_test() {
  let assert Ok(sub_id) = json.parse("\"1\"", subscription_id.decoder())
  assert "1" == subscription_id.to_string(sub_id)
}

pub fn decoder_returns_error_when_value_is_invalid_test() {
  let assert Error(_) = json.parse("", subscription_id.decoder())
}
