import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option, None}

pub type CmcCryptoCurrency {
  CmcCryptoCurrency(id: Int, rank: Option(Int), name: String, symbol: String)
}

pub fn decoder() -> Decoder(CmcCryptoCurrency) {
  use id <- decode.field("id", decode.int)
  use rank <- decode.optional_field("rank", None, decode.optional(decode.int))
  use name <- decode.field("name", decode.string)
  use symbol <- decode.field("symbol", decode.string)
  decode.success(CmcCryptoCurrency(id, rank, name, symbol))
}
