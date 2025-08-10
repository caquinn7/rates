import gleam/dynamic/decode
import lustre/effect.{type Effect}
import rsvp
import shared/currency.{type Currency}

pub fn get_currency(
  symbol: String,
  handler: fn(Result(List(Currency), rsvp.Error)) -> msg,
) -> Effect(msg) {
  let currencies_decoder = decode.list(currency.decoder())
  let handler = rsvp.expect_json(currencies_decoder, handler)
  rsvp.get("/api/currencies?symbol=" <> symbol, handler)
}
