import gleam/int
import gleam/option.{type Option, None, Some}
import server/domain/rates/internal/kraken_symbol.{type KrakenSymbol}
import shared/rates/rate_request.{type RateRequest}

pub opaque type SubscriptionManager {
  SubscriptionManager(
    subscription: Option(Subscription),
    intervals: SubscriberIntervals,
  )
}

pub type Subscription {
  Kraken(RateRequest, KrakenSymbol)
  Cmc(RateRequest)
}

type SubscriberIntervals {
  SubscriberIntervals(base: Int, current: Int)
}

pub fn new(base_interval: Int) -> Result(SubscriptionManager, String) {
  case base_interval {
    i if i <= 0 -> Error("Interval must be positive")
    i if i < 1000 -> Error("Interval must be at least 1000ms")
    _ ->
      Ok(SubscriptionManager(
        subscription: None,
        intervals: SubscriberIntervals(base_interval, base_interval),
      ))
  }
}

pub fn create_kraken_subscription(
  manager: SubscriptionManager,
  rate_request: RateRequest,
  symbol: KrakenSymbol,
) -> SubscriptionManager {
  SubscriptionManager(
    subscription: Some(Kraken(rate_request, symbol)),
    intervals: SubscriberIntervals(
      ..manager.intervals,
      current: manager.intervals.base,
    ),
  )
}

pub fn create_cmc_subscription(
  manager: SubscriptionManager,
  rate_request: RateRequest,
) -> SubscriptionManager {
  SubscriptionManager(
    subscription: Some(Cmc(rate_request)),
    intervals: SubscriberIntervals(
      ..manager.intervals,
      current: int.max(manager.intervals.base, 30_000),
    ),
  )
}

pub fn get_current_interval(manager: SubscriptionManager) -> Int {
  manager.intervals.current
}

pub fn get_subscription(manager: SubscriptionManager) -> Option(Subscription) {
  manager.subscription
}

pub fn clear_subscription(manager: SubscriptionManager) -> SubscriptionManager {
  SubscriptionManager(..manager, subscription: None)
}
