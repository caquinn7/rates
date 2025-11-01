import gleam/json
import gleam/option.{None, Some}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  CmcCryptoCurrency,
}

pub fn decode_crypto_currency_test() {
  let result =
    "{\"id\":1,\"rank\":1,\"name\":\"Bitcoin\",\"symbol\":\"BTC\"}"
    |> json.parse(cmc_crypto_currency.decoder())

  assert Ok(CmcCryptoCurrency(1, Some(1), "Bitcoin", "BTC")) == result
}

pub fn decode_crypto_currency_with_no_rank_test() {
  let result =
    "{\"id\":1,\"rank\":null,\"name\":\"Bitcoin\",\"symbol\":\"BTC\"}"
    |> json.parse(cmc_crypto_currency.decoder())

  assert Ok(CmcCryptoCurrency(1, None, "Bitcoin", "BTC")) == result
}
