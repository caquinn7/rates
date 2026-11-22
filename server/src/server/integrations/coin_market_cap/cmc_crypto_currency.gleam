import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option, None}

/// An entry in CoinMarketCap's cryptocurrency map.
pub type CmcCryptoCurrency {
  CmcCryptoCurrency(
    /// CoinMarketCap ID of the cryptocurrency.
    id: Int,
    /// CoinMarketCap market cap rank, or `None` if omitted or null.
    rank: Option(Int),
    /// Full name of the cryptocurrency, such as `Bitcoin`.
    name: String,
    /// Symbol of the cryptocurrency, such as `BTC`.
    symbol: String,
  )
}

pub fn decoder() -> Decoder(CmcCryptoCurrency) {
  use id <- decode.field("id", decode.int)
  use rank <- decode.optional_field("rank", None, decode.optional(decode.int))
  use name <- decode.field("name", decode.string)
  use symbol <- decode.field("symbol", decode.string)
  decode.success(CmcCryptoCurrency(id, rank, name, symbol))
}
