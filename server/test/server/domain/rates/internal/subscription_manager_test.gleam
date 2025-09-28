import gleam/option.{None, Some}
import server/domain/rates/internal/kraken_symbol
import server/domain/rates/internal/subscription_manager.{Cmc, Kraken}
import shared/rates/rate_request.{RateRequest}

pub fn new_returns_error_when_interval_is_not_positive_test() {
  assert Error("Interval must be positive") == subscription_manager.new(0)
  assert Error("Interval must be positive") == subscription_manager.new(-1)
}

pub fn new_returns_error_when_interval_is_less_than_1000_test() {
  assert Error("Interval must be at least 1000ms")
    == subscription_manager.new(999)
}

pub fn new_returns_manager_with_no_subscription_test() {
  let assert Ok(result) = subscription_manager.new(1000)

  assert None == subscription_manager.get_subscription(result)
  assert 1000 == subscription_manager.get_current_interval(result)
}

pub fn create_kraken_subscription_returns_manager_with_kraken_subscription_test() {
  let assert Ok(kraken_symbol) =
    kraken_symbol.new(#("BTC", "USD"), fn(_) { True })

  let rate_request = RateRequest(1, 2)

  let assert Ok(manager) = subscription_manager.new(1000)

  let manager =
    manager
    |> subscription_manager.create_kraken_subscription(
      rate_request,
      kraken_symbol,
    )

  assert Some(Kraken(rate_request, kraken_symbol))
    == subscription_manager.get_subscription(manager)

  assert 1000 == subscription_manager.get_current_interval(manager)
}

pub fn create_cmc_subscription_returns_manager_with_cmc_subscription_test() {
  let rate_request = RateRequest(1, 2)

  let assert Ok(manager) = subscription_manager.new(1000)

  let manager =
    manager
    |> subscription_manager.create_cmc_subscription(rate_request)

  assert Some(Cmc(rate_request))
    == subscription_manager.get_subscription(manager)

  assert 30_000 == subscription_manager.get_current_interval(manager)
}

pub fn create_cmc_subscription_uses_base_interval_when_greater_than_30000_test() {
  let assert Ok(manager) = subscription_manager.new(50_000)

  let manager =
    manager
    |> subscription_manager.create_cmc_subscription(RateRequest(1, 2))

  assert 50_000 == subscription_manager.get_current_interval(manager)
}

pub fn clear_subscription_returns_manager_with_no_subscription_test() {
  let assert Ok(manager) = subscription_manager.new(50_000)

  let manager =
    manager
    |> subscription_manager.create_cmc_subscription(RateRequest(1, 2))
    |> subscription_manager.clear_subscription

  assert None == subscription_manager.get_subscription(manager)
  assert 50_000 == subscription_manager.get_current_interval(manager)
}
