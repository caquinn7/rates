import gleam/json
import server/integrations/coin_market_cap/cmc_fiat_currency.{CmcFiatCurrency}

pub fn decode_fiat_currency_test() {
  let result =
    "{\"id\":2781,\"name\":\"United States Dollar\",\"sign\":\"$\",\"symbol\":\"USD\"}"
    |> json.parse(cmc_fiat_currency.decoder())

  assert Ok(CmcFiatCurrency(2781, "United States Dollar", "$", "USD")) == result
}
