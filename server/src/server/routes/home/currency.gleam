import gleam/json.{type Json}
import shared/currency.{type Currency, Crypto, Fiat}

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
