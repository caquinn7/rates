import gleam/erlang/process
import gleam/option.{Some}
import server/dependencies.{Dependencies}
import server/domain/rates/factories
import server/domain/rates/internal/kraken_interface.{KrakenInterface}
import server/domain/rates/internal/kraken_symbol
import server/domain/rates/subscriber
import server/integrations/kraken/price_store
import server/utils/logger
import shared/currency.{Crypto, Fiat}
import shared/rates/rate_request.{RateRequest}
import shared/rates/rate_response.{Kraken}
import shared/subscriptions/subscription_id

pub fn subscriber_subscribe_happy_path_test() {
  // arrange
  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()

  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { Nil },
      unsubscribe: fn(_) { Nil },
      check_for_price: fn(_) { Ok(price_store.PriceEntry(100_000.0, 1)) },
    )

  let deps =
    Dependencies(
      currencies:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) { panic },
      get_current_time_ms: fn() { panic },
      logger: logger.new(),
    )

  let subscriber_factory = factories.create_rate_subscriber_factory(deps)
  let target = subscriber_factory(sub_id, subject)

  // act: Subscribe to BTC -> USD conversion
  subscriber.subscribe(target, RateRequest(1, 2781))
  subscriber.stop(target)

  // assert: Should receive successful rate response
  let assert Ok(#(received_sub_id, result)) = process.receive(subject, 1000)
  let assert Ok(rate_response) = result

  assert sub_id == received_sub_id
  assert 1 == rate_response.from
  assert 2781 == rate_response.to
  assert 100_000.0 == rate_response.rate
  assert Kraken == rate_response.source
}
