import gleam/option.{type Option, Some}
import server/currencies/cmc_currency_handler.{type RequestCmcFiats}
import server/integrations/coin_market_cap/client.{
  type CmcListResponse, type CmcRequestError,
}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  type CmcCryptoCurrency,
}
import server/rates/internal/cmc_rate_handler.{type RequestCmcConversion}

/// Creates a cryptocurrency requester with the API key and result limit bound.
/// The returned function accepts an optional symbol filter and performs a request
/// when called.
pub fn create_crypto_requester(
  cmc_api_key: String,
  crypto_limit: Int,
) -> fn(Option(String)) ->
  Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError) {
  client.get_crypto_currencies(cmc_api_key, Some(crypto_limit), _)
}

/// Creates a zero-argument fiat-currency requester with the API key bound.
/// Each call requests fiat currencies with a fixed result limit of 100.
pub fn create_fiat_requester(cmc_api_key: String) -> RequestCmcFiats {
  fn() { client.get_fiat_currencies(cmc_api_key, Some(100)) }
}

/// Creates a conversion requester with the API key bound.
/// The returned function accepts `CmcConversionParameters` specifying the amount
/// and source and target currency IDs, and performs a request when called.
pub fn create_conversion_requester(
  cmc_api_key: String,
) -> RequestCmcConversion {
  client.get_conversion(cmc_api_key, _)
}
