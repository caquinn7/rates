import gleam/option.{type Option}

pub type Currency {
  Crypto(id: Int, name: String, symbol: String, rank: Option(Int))
  Fiat(id: Int, name: String, symbol: String, sign: String)
}
