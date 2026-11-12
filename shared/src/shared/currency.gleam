import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option, None}

/// Currency metadata shared by the server and client.
///
/// The CoinMarketCap `id` identifies the currency in rate requests and saved state.
pub type Currency {
  /// A cryptocurrency with an optional provider rank.
  ///
  /// Lower ranks sort first in currency selectors; `None` means no rank was supplied.
  ///
  /// ```gleam
  /// Crypto(
  ///   id: 1,
  ///   name: "Bitcoin",
  ///   symbol: "BTC",
  ///   rank: Some(1),
  /// )
  /// ```
  Crypto(id: Int, name: String, symbol: String, rank: Option(Int))

  /// A fiat currency with a monetary `sign`, such as `$` or `€`.
  ///
  /// ```gleam
  /// Fiat(
  ///   id: 2781,
  ///   name: "United States Dollar",
  ///   symbol: "USD",
  ///   sign: "$",
  /// )
  /// ```
  Fiat(id: Int, name: String, symbol: String, sign: String)
}

/// Encodes a currency as a JSON object with a `type` of `"crypto"` or `"fiat"`.
/// Both variants include `id`, `name`, and `symbol`. Cryptocurrencies include
/// `rank` as an integer or `null`; fiat currencies include `sign`.
pub fn encode(currency: Currency) -> Json {
  case currency {
    Crypto(id, name, symbol, rank) ->
      json.object([
        #("type", json.string("crypto")),
        #("id", json.int(id)),
        #("name", json.string(name)),
        #("symbol", json.string(symbol)),
        #("rank", json.nullable(rank, json.int)),
      ])

    Fiat(id, name, symbol, sign) ->
      json.object([
        #("type", json.string("fiat")),
        #("id", json.int(id)),
        #("name", json.string(name)),
        #("symbol", json.string(symbol)),
        #("sign", json.string(sign)),
      ])
  }
}

/// Decodes the currency JSON format produced by `encode`, using `type` to select
/// the variant. All fields for that variant are required; a crypto `rank` may be
/// `null`, which decodes to `None`.
///
/// Unknown types, missing fields, or values of the wrong type fail decoding.
pub fn decoder() {
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
    _ -> decode.failure(Crypto(0, "", "", None), "Currency")
  }
}
