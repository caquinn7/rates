import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/client_state.{type ConverterState}
import shared/currency.{type Currency}

/// Initial data needed to render the currency exchange rate page.
/// Includes the currency catalog and converter state. Quotes arrive over WebSocket.
pub type PageData {
  PageData(currencies: List(Currency), converters: List(ConverterState))
}

pub fn encode(start_data: PageData) -> Json {
  json.object([
    #("currencies", json.array(start_data.currencies, currency.encode)),
    #(
      "converters",
      json.string(client_state.encode_converter_states(start_data.converters)),
    ),
  ])
}

pub fn decoder() -> Decoder(PageData) {
  use currencies <- decode.field("currencies", decode.list(currency.decoder()))
  use converters <- decode.field("converters", {
    use encoded_str <- decode.then(decode.string)
    case client_state.decode_converter_states(encoded_str) {
      Ok(states) -> decode.success(states)
      Error(_) -> decode.failure([], "ConverterState")
    }
  })
  decode.success(PageData(currencies:, converters:))
}
