import gleam/int
import gleam/option.{type Option, None, Some}
import server/rates/internal/kraken_symbol.{type KrakenSymbol}
import shared/rates/rate_request.{type RateRequest}

pub opaque type SubscriptionManager {
  SubscriptionManager(subscription: Option(Subscription), base_interval: Int)
}

pub type Subscription {
  Kraken(RateRequest, KrakenSymbol)
  Cmc(RateRequest)
}

pub fn new(base_interval: Int) -> Result(SubscriptionManager, String) {
  case base_interval {
    i if i <= 0 -> Error("Interval must be positive")
    i if i < 1000 -> Error("Interval must be at least 1000ms")
    _ -> Ok(SubscriptionManager(subscription: None, base_interval:))
  }
}

pub fn create_kraken_subscription(
  manager: SubscriptionManager,
  rate_request: RateRequest,
  symbol: KrakenSymbol,
) -> SubscriptionManager {
  SubscriptionManager(
    ..manager,
    subscription: Some(Kraken(rate_request, symbol)),
  )
}

pub fn create_cmc_subscription(
  manager: SubscriptionManager,
  rate_request: RateRequest,
) -> SubscriptionManager {
  SubscriptionManager(..manager, subscription: Some(Cmc(rate_request)))
}

/// Returns the base interval, with a 30-second minimum for an active CMC subscription.
pub fn get_current_interval(manager: SubscriptionManager) -> Int {
  case manager.subscription {
    Some(Cmc(_)) -> int.max(manager.base_interval, 30_000)
    _ -> manager.base_interval
  }
}

pub fn get_subscription(manager: SubscriptionManager) -> Option(Subscription) {
  manager.subscription
}

pub fn clear_subscription(manager: SubscriptionManager) -> SubscriptionManager {
  SubscriptionManager(..manager, subscription: None)
}
