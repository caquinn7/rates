import gleam/dynamic/decode.{type Decoder}

pub type CmcFiatCurrency {
  CmcFiatCurrency(id: Int, name: String, sign: String, symbol: String)
}

pub fn decoder() -> Decoder(CmcFiatCurrency) {
  use id <- decode.field("id", decode.int)
  use name <- decode.field("name", decode.string)
  use sign <- decode.field("sign", decode.string)
  use symbol <- decode.field("symbol", decode.string)
  decode.success(CmcFiatCurrency(id, name, sign, symbol))
}
