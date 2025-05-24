import client/rates/rate_response
import gleam/dynamic/decode.{type Decoder}
import shared/currency.{type Currency, Crypto, Fiat}
import shared/rates/rate_response.{type RateResponse} as _shared_rate_response

pub type StartData {
  StartData(currencies: List(Currency), rate: RateResponse)
}

pub fn decoder() -> Decoder(StartData) {
  let currency_decoder = fn() {
    use variant <- decode.field("type", decode.string)
    case variant {
      "crypto" -> {
        use id <- decode.field("id", decode.int)
        use name <- decode.field("name", decode.string)
        use symbol <- decode.field("symbol", decode.string)
        use rank <- decode.field("rank", decode.optional(decode.int))
        decode.success(Crypto(id:, name:, symbol:, rank:))
      }
      "fiat" -> {
        use id <- decode.field("id", decode.int)
        use name <- decode.field("name", decode.string)
        use symbol <- decode.field("symbol", decode.string)
        use sign <- decode.field("sign", decode.string)
        decode.success(Fiat(id:, name:, symbol:, sign:))
      }
      _ -> panic as "invalid currency type"
    }
  }

  use currencies <- decode.field("currencies", decode.list(currency_decoder()))
  use rate <- decode.field("rate", rate_response.decoder())
  decode.success(StartData(currencies:, rate:))
}
