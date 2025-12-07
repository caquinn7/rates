import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/client_state.{type ConverterState}
import shared/currency.{type Currency}
import shared/rates/rate_response.{type RateResponse}

/// Initial data needed to render the currency exchange rate page.
/// Includes all available currencies for selection and the current rate displays.
pub type PageData {
  PageData(
    currencies: List(Currency),
    rates: List(RateResponse),
    converters: List(ConverterState),
  )
}

pub fn encode(start_data: PageData) -> Json {
  json.object([
    #("currencies", json.array(start_data.currencies, currency.encode)),
    #("rate", json.array(start_data.rates, rate_response.encode)),
    #(
      "converters",
      json.string(client_state.encode_converter_states(start_data.converters)),
    ),
  ])
}

pub fn decoder() -> Decoder(PageData) {
  use currencies <- decode.field("currencies", decode.list(currency.decoder()))
  use rates <- decode.field("rate", decode.list(rate_response.decoder()))
  use converters <- decode.field("converters", {
    use encoded_str <- decode.then(decode.string)
    case client_state.decode_converter_states(encoded_str) {
      Error(_) -> decode.failure([], "ConverterState")
      Ok(states) -> decode.success(states)
    }
  })
  decode.success(PageData(currencies:, rates:, converters:))
}
