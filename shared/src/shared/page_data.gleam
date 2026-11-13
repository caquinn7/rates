import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import shared/client_state.{type ConverterState, ConverterState}
import shared/currency.{type Currency}

/// Initial data needed to render the currency exchange rate page.
/// Includes the currency catalog and converter state. Quotes arrive over WebSocket.
pub type PageData {
  PageData(currencies: List(Currency), converters: List(ConverterState))
}

pub fn encode(start_data: PageData) -> Json {
  json.object([
    #("currencies", json.array(start_data.currencies, currency.encode)),
    #("converters", json.array(start_data.converters, encode_converter_state)),
  ])
}

pub fn decoder() -> Decoder(PageData) {
  use currencies <- decode.field("currencies", decode.list(currency.decoder()))
  use converters <- decode.field(
    "converters",
    decode.list(converter_state_decoder()),
  )
  decode.success(PageData(currencies:, converters:))
}

fn encode_converter_state(state: ConverterState) -> Json {
  json.object([
    #("from", json.int(state.from)),
    #("to", json.int(state.to)),
    #("amount", json.float(state.amount)),
  ])
}

fn converter_state_decoder() -> Decoder(ConverterState) {
  use from <- decode.field("from", decode.int)
  use to <- decode.field("to", decode.int)
  use amount <- decode.field(
    "amount",
    decode.one_of(decode.float, [decode.map(decode.int, int.to_float)]),
  )
  decode.success(ConverterState(from:, to:, amount:))
}
