import gleam/int
import gleam/option.{type Option, None, Some}
import server/rates/internal/kraken_symbol.{type KrakenSymbol}
import shared/rates/rate_request.{type RateRequest}

/// Tracks a subscriber's optional active subscription and base refresh interval
/// in milliseconds. Kraken uses the base interval; CMC uses the greater of the
/// base interval and 30 seconds. With no subscription, the base interval applies.
pub opaque type SubscriptionManager {
  SubscriptionManager(subscription: Option(Subscription), base_interval: Int)
}

/// An active rate request and the provider selected to refresh it.
pub type Subscription {
  /// Carries the rate request and resolved Kraken pair, including its price direction.
  Kraken(RateRequest, KrakenSymbol)
  /// A CoinMarketCap request, selected directly or as a fallback from Kraken.
  Cmc(RateRequest)
}

/// Creates a manager with no active subscription and a base interval in milliseconds.
///
/// Requires an interval of at least 1000ms. Returns a descriptive error for
/// nonpositive intervals or positive intervals below that minimum.
pub fn new(base_interval: Int) -> Result(SubscriptionManager, String) {
  case base_interval {
    i if i <= 0 -> Error("Interval must be positive")
    i if i < 1000 -> Error("Interval must be at least 1000ms")
    _ -> Ok(SubscriptionManager(subscription: None, base_interval:))
  }
}

/// Replaces the active subscription while preserving the configured base interval.
pub fn set_subscription(
  manager: SubscriptionManager,
  subscription: Subscription,
) -> SubscriptionManager {
  SubscriptionManager(..manager, subscription: Some(subscription))
}

/// Returns the base interval, with a 30-second minimum for an active CMC subscription.
pub fn get_current_interval(manager: SubscriptionManager) -> Int {
  case manager.subscription {
    Some(Cmc(_)) -> int.max(manager.base_interval, 30_000)
    _ -> manager.base_interval
  }
}

/// Returns the active subscription, or `None` if no subscription is set.
pub fn get_subscription(manager: SubscriptionManager) -> Option(Subscription) {
  manager.subscription
}

/// Clears the active subscription while preserving the configured base interval.
/// Subsequent interval lookups return that base interval.
pub fn clear_subscription(manager: SubscriptionManager) -> SubscriptionManager {
  SubscriptionManager(..manager, subscription: None)
}
