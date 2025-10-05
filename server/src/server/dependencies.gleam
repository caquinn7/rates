import gleam/option.{type Option}
import server/domain/rates/internal/kraken_interface.{type KrakenInterface}
import server/integrations/coin_market_cap/client.{
  type CmcConversion, type CmcConversionParameters, type CmcCryptoCurrency,
  type CmcListResponse, type CmcRequestError, type CmcResponse,
}
import server/utils/logger.{type Logger}
import shared/currency.{type Currency}

pub type Dependencies {
  Dependencies(
    currencies: List(Currency),
    subscription_refresh_interval_ms: Int,
    kraken_interface: KrakenInterface,
    request_cmc_cryptos: fn(Option(String)) ->
      Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError),
    request_cmc_conversion: fn(CmcConversionParameters) ->
      Result(CmcResponse(CmcConversion), CmcRequestError),
    get_current_time_ms: fn() -> Int,
    logger: Logger,
  )
}
