import server/rates/internal/cmc_rate_handler.{type RequestCmcConversion}
import server/rates/internal/kraken_interface.{type KrakenInterface}
import server/utils/logger.{type Logger}
import shared/currency.{type Currency}

/// Validated dependencies and refresh settings for a rate subscriber.
pub opaque type SubscriberConfig {
  SubscriberConfig(
    currency_lookup: fn(Int) -> Result(Currency, Nil),
    kraken_interface: KrakenInterface,
    cmc_conversion_fetcher: RequestCmcConversion,
    base_refresh_interval_ms: Int,
    logger: Logger,
  )
}

/// Builds a `SubscriberConfig` with a base refresh interval of at least 1000 ms.
pub fn new(
  currency_lookup: fn(Int) -> Result(Currency, Nil),
  kraken_interface: KrakenInterface,
  cmc_conversion_fetcher: RequestCmcConversion,
  base_refresh_interval_ms: Int,
  logger: Logger,
) -> Result(SubscriberConfig, String) {
  case base_refresh_interval_ms {
    interval if interval <= 0 -> Error("Interval must be positive")
    interval if interval < 1000 -> Error("Interval must be at least 1000ms")
    _ ->
      Ok(SubscriberConfig(
        currency_lookup:,
        kraken_interface:,
        cmc_conversion_fetcher:,
        base_refresh_interval_ms:,
        logger:,
      ))
  }
}

/// Returns the function that looks up a currency by ID.
pub fn get_currency_lookup(
  config: SubscriberConfig,
) -> fn(Int) -> Result(Currency, Nil) {
  config.currency_lookup
}

pub fn get_kraken_interface(config: SubscriberConfig) -> KrakenInterface {
  config.kraken_interface
}

/// Returns the function that fetches a CoinMarketCap conversion.
pub fn get_cmc_conversion_fetcher(
  config: SubscriberConfig,
) -> RequestCmcConversion {
  config.cmc_conversion_fetcher
}

pub fn get_base_refresh_interval_ms(config: SubscriberConfig) -> Int {
  config.base_refresh_interval_ms
}

pub fn get_logger(config: SubscriberConfig) -> Logger {
  config.logger
}
