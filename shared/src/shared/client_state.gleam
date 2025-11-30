import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/currency.{type Currency}

pub type ClientState {
  ClientState(
    added_currencies: List(Currency),
    converter_states: List(ConverterState),
  )
}

pub type ConverterState {
  ConverterState(from: Int, to: Int, amount: String)
}

pub fn encode(client_state: ClientState) -> Json {
  let ClientState(added_currencies:, converter_states:) = client_state

  json.object([
    #("added_currencies", json.array(added_currencies, currency.encode)),
    #("converter_states", json.array(converter_states, encode_converter_state)),
  ])
}

pub fn decoder() -> Decoder(ClientState) {
  use added_currencies <- decode.field(
    "added_currencies",
    decode.list(currency.decoder()),
  )
  use converter_states <- decode.field(
    "converter_states",
    decode.list(converter_state_decoder()),
  )
  decode.success(ClientState(added_currencies:, converter_states:))
}

fn encode_converter_state(converter_state: ConverterState) -> Json {
  let ConverterState(from:, to:, amount:) = converter_state

  json.object([
    #("from", json.int(from)),
    #("to", json.int(to)),
    #("amount", json.string(amount)),
  ])
}

fn converter_state_decoder() -> Decoder(ConverterState) {
  use from <- decode.field("from", decode.int)
  use to <- decode.field("to", decode.int)
  use amount <- decode.field("amount", decode.string)
  decode.success(ConverterState(from:, to:, amount:))
}
