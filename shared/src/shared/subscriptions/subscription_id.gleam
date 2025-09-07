import gleam/dynamic/decode.{type Decoder}
import gleam/string

pub opaque type SubscriptionId {
  SubscriptionId(id: String)
}

pub fn new(value: String) -> Result(SubscriptionId, Nil) {
  case string.trim(value) {
    "" -> Error(Nil)
    s -> Ok(SubscriptionId(s))
  }
}

pub fn to_string(id: SubscriptionId) -> String {
  let SubscriptionId(unwrapped) = id
  unwrapped
}

pub fn decoder() -> Decoder(SubscriptionId) {
  use str <- decode.then(decode.string)
  case new(str) {
    Error(_) -> decode.failure(SubscriptionId(""), "SubscriptionId")
    Ok(id) -> decode.success(id)
  }
}
