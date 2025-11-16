import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/option.{type Option}

pub type CmcConversion {
  CmcConversion(
    id: Int,
    symbol: String,
    name: String,
    amount: Float,
    quote: Dict(String, QuoteItem),
  )
}

pub type QuoteItem {
  QuoteItem(price: Option(Float))
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
  use amount <- decode.field("amount", int_or_float_decoder())
  use quote <- decode.field(
    "quote",
    decode.dict(decode.string, quote_item_decoder()),
  )
  decode.success(CmcConversion(id, symbol, name, amount, quote))
}

pub fn quote_item_decoder() -> Decoder(QuoteItem) {
  use price <- decode.field("price", decode.optional(int_or_float_decoder()))
  decode.success(QuoteItem(price))
}

fn int_or_float_decoder() -> Decoder(Float) {
  decode.one_of(decode.float, or: [decode.map(decode.int, int.to_float)])
}
