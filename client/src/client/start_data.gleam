import client/rates/rate_response
import gleam/dynamic/decode.{type Decoder}
import shared/currency.{type Currency}
import shared/rates/rate_response.{type RateResponse} as _shared_rate_response

pub type StartData {
  StartData(currencies: List(Currency), rate: RateResponse)
}

pub fn decoder() -> Decoder(StartData) {
  use currencies <- decode.field("currencies", decode.list(currency.decoder()))
  use rate <- decode.field("rate", rate_response.decoder())
  decode.success(StartData(currencies:, rate:))
}
