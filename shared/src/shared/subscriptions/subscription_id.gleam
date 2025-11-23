import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/string

pub opaque type SubscriptionId {
  SubscriptionId(String)
}

pub fn new(value: String) -> Result(SubscriptionId, Nil) {
  case string.trim(value) {
    "" -> Error(Nil)
    trimmed -> Ok(SubscriptionId(trimmed))
  }
}

pub fn from_string_unsafe(value: String) -> SubscriptionId {
  let assert Ok(sub_id) = new(value) as "invalid subscription id"
  sub_id
}

pub fn to_string(id: SubscriptionId) -> String {
  let SubscriptionId(unwrapped) = id
  unwrapped
}

pub fn encode(id: SubscriptionId) -> Json {
  json.string(to_string(id))
}

pub fn decoder() -> Decoder(SubscriptionId) {
  use str <- decode.then(decode.string)
  case new(str) {
    Error(_) -> decode.failure(SubscriptionId(""), "SubscriptionId")
    Ok(id) -> decode.success(id)
  }
}
