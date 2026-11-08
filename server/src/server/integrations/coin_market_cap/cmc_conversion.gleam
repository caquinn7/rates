import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option}
import server/utils/time
import shared/numbers/positive_float.{type PositiveFloat}

pub type CmcConversion {
  CmcConversion(
    id: Int,
    symbol: String,
    name: String,
    amount: PositiveFloat,
    quote: Dict(String, QuoteItem),
  )
}

pub type QuoteItem {
  /// The quote's last update time in Unix milliseconds.
  QuoteItem(price: Option(PositiveFloat), last_updated: Int)
}

pub fn decoder() -> Decoder(CmcConversion) {
  // {
  //     "id": 1,
  //     "symbol": "BTC",
  //     "name": "Bitcoin",
  //     "amount": 1.5,
  //     "last_updated": "2024-09-27T20:57:00.000Z",
  //     "quote": {
  //         "2010": {
  //             "price": 245304.45530431595,
  //             "last_updated": "2024-09-27T20:57:00.000Z"
  //         }
  //     }
  // }

  use id <- decode.field("id", decode.int)
  use symbol <- decode.field("symbol", decode.string)
  use name <- decode.field("name", decode.string)
  use amount <- decode.field("amount", positive_float.decoder())
  use quote <- decode.field(
    "quote",
    decode.dict(decode.string, quote_item_decoder()),
  )
  decode.success(CmcConversion(id, symbol, name, amount, quote))
}

pub fn quote_item_decoder() -> Decoder(QuoteItem) {
  use price <- decode.field("price", decode.optional(positive_float.decoder()))
  use last_updated <- decode.field("last_updated", time.rfc3339_ms_decoder())
  decode.success(QuoteItem(price, last_updated))
}
