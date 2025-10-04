import gleam/option.{type Option, Some}
import server/integrations/coin_market_cap/client.{
  type CmcConversion, type CmcConversionParameters, type CmcCryptoCurrency,
  type CmcFiatCurrency, type CmcListResponse, type CmcRequestError,
  type CmcResponse,
}

pub fn create_crypto_requester(
  cmc_api_key: String,
  crypto_limit: Int,
) -> fn(Option(String)) ->
  Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError) {
  client.get_crypto_currencies(cmc_api_key, Some(crypto_limit), _)
}

pub fn create_fiat_requester(
  cmc_api_key: String,
) -> fn() -> Result(CmcListResponse(CmcFiatCurrency), CmcRequestError) {
  fn() { client.get_fiat_currencies(cmc_api_key, Some(100)) }
}

pub fn create_conversion_requester(
  cmc_api_key: String,
) -> fn(CmcConversionParameters) ->
  Result(CmcResponse(CmcConversion), CmcRequestError) {
  client.get_conversion(cmc_api_key, _)
}
