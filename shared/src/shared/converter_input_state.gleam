import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}

pub type ConverterInputState {
  ConverterInputState(from: Int, to: Int, amount: String)
}

pub fn encode(converter_input_state: ConverterInputState) -> Json {
  let ConverterInputState(from:, to:, amount:) = converter_input_state

  json.object([
    #("from", json.int(from)),
    #("to", json.int(to)),
    #("amount", json.string(amount)),
  ])
}

pub fn decoder() -> Decoder(ConverterInputState) {
  use from <- decode.field("from", decode.int)
  use to <- decode.field("to", decode.int)
  use amount <- decode.field("amount", decode.string)
  decode.success(ConverterInputState(from:, to:, amount:))
}
