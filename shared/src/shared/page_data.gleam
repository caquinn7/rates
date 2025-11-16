import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/currency.{type Currency}
import shared/rates/rate_response.{type RateResponse}

/// Initial data needed to render the currency exchange rate page.
/// Includes all available currencies for selection and the current rate displays.
pub type PageData {
  PageData(currencies: List(Currency), rates: List(RateResponse))
}

pub fn encode(start_data: PageData) -> Json {
  json.object([
    #("currencies", json.array(start_data.currencies, currency.encode)),
    #("rate", json.array(start_data.rates, rate_response.encode)),
  ])
}

pub fn decoder() -> Decoder(PageData) {
  use currencies <- decode.field("currencies", decode.list(currency.decoder()))
  use rates <- decode.field("rate", decode.list(rate_response.decoder()))
  decode.success(PageData(currencies:, rates:))
}
