import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option, None}

pub type Currency {
  Crypto(id: Int, name: String, symbol: String, rank: Option(Int))
  Fiat(id: Int, name: String, symbol: String, sign: String)
}

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
