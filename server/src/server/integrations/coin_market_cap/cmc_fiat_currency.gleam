import gleam/dynamic/decode.{type Decoder}

/// An entry in CoinMarketCap's fiat currency map.
pub type CmcFiatCurrency {
  CmcFiatCurrency(
    /// CoinMarketCap ID of the fiat currency.
    id: Int,
    /// Full name of the fiat currency, such as `United States Dollar`.
    name: String,
    /// Currency sign used to display amounts, such as `$`.
    sign: String,
    /// Currency code, such as `USD`.
    symbol: String,
  )
}

pub fn decoder() -> Decoder(CmcFiatCurrency) {
  use id <- decode.field("id", decode.int)
  use name <- decode.field("name", decode.string)
  use sign <- decode.field("sign", decode.string)
  use symbol <- decode.field("symbol", decode.string)
  decode.success(CmcFiatCurrency(id, name, sign, symbol))
}
