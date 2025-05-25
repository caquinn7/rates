pub type RateResponse {
  RateResponse(from: Int, to: Int, rate: Float, source: Source)
}

pub type Source {
  CoinMarketCap
  Kraken
}

pub fn source_to_string(source: Source) {
  case source {
    CoinMarketCap -> "CoinMarketCap"
    Kraken -> "Kraken"
  }
}
