import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/converter_input_state.{type ConverterInputState}
import shared/currency.{type Currency}
import shared/rates/rate_response.{type RateResponse}

/// Initial data needed to render the currency exchange rate page.
/// Includes all available currencies for selection and the current rate displays.
pub type PageData {
  PageData(
    currencies: List(Currency),
    rates: List(RateResponse),
    state: List(ConverterInputState),
  )
}

pub fn encode(page_data: PageData) -> Json {
  let PageData(currencies:, rates:, state:) = page_data

  json.object([
    #("currencies", json.array(currencies, currency.encode)),
    #("rates", json.array(rates, rate_response.encode)),
    #("state", json.array(state, converter_input_state.encode)),
  ])
}

pub fn decoder() -> Decoder(PageData) {
  use currencies <- decode.field("currencies", decode.list(currency.decoder()))
  use rates <- decode.field("rates", decode.list(rate_response.decoder()))
  use state <- decode.field(
    "state",
    decode.list(converter_input_state.decoder()),
  )
  decode.success(PageData(currencies:, rates:, state:))
}
