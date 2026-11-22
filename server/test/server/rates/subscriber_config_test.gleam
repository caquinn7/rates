import gleam/list
import server/rates/internal/kraken_interface.{KrakenInterface}
import server/rates/subscriber_config
import server/utils/logger

pub fn new_rejects_invalid_base_refresh_intervals_test() {
  list.each(
    [
      #(0, "Interval must be positive"),
      #(-1, "Interval must be positive"),
      #(999, "Interval must be at least 1000ms"),
    ],
    fn(test_case) {
      let #(interval, message) = test_case
      assert new_config(interval) == Error(message)
    },
  )
}

pub fn new_accepts_minimum_base_refresh_interval_test() {
  let assert Ok(config) = new_config(1000)
  assert subscriber_config.get_base_refresh_interval_ms(config) == 1000
}

fn new_config(base_refresh_interval_ms: Int) {
  subscriber_config.new(
    fn(_) { panic },
    KrakenInterface(
      get_kraken_symbol: fn(_) { panic },
      subscribe: fn(_) { panic },
      unsubscribe: fn(_) { panic },
      check_for_price: fn(_) { panic },
    ),
    fn(_) { panic },
    base_refresh_interval_ms,
    logger.new(),
  )
}
