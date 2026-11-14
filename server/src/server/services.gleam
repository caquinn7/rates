import server/currencies/currency_repository.{type CurrencyRepository}
import server/currencies/currency_symbol_cache.{type CurrencySymbolCache}
import server/rates/subscriber_factory.{type SubscriberFactory}
import server/utils/logger.{type Logger}

/// Application services assembled at startup and shared by HTTP and WebSocket
/// handlers.
pub type Services {
  Services(
    currency_repository: CurrencyRepository,
    currency_symbol_cache: CurrencySymbolCache,
    create_rate_subscriber: SubscriberFactory,
    logger: Logger,
  )
}
