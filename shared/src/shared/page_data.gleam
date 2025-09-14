import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/currency.{type Currency}
import shared/rates/rate_response.{type RateResponse}

/// Initial data needed to render the currency exchange rate page.
/// Includes all available currencies for selection and the current rate display.
pub type PageData {
  PageData(currencies: List(Currency), rate: RateResponse)
}

pub fn encode(start_data: PageData) -> Json {
  json.object([
    #("currencies", json.array(start_data.currencies, currency.encode)),
    #("rate", rate_response.encode(start_data.rate)),
  ])
}

pub fn decoder() -> Decoder(PageData) {
  use currencies <- decode.field("currencies", decode.list(currency.decoder()))
  use rate <- decode.field("rate", rate_response.decoder())
  decode.success(PageData(currencies:, rate:))
}
