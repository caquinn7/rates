import gleam/dict
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/option.{None, Some}
import server/dependencies.{Dependencies}
import server/domain/rates/factories
import server/domain/rates/internal/kraken_interface.{KrakenInterface}
import server/domain/rates/internal/kraken_symbol
import server/domain/rates/rate_error.{CmcError, CurrencyNotFound}
import server/domain/rates/subscriber
import server/integrations/coin_market_cap/client.{
  CmcConversion, CmcResponse, CmcStatus, QuoteItem,
}
import server/integrations/kraken/price_store.{PriceEntry}
import server/utils/logger
import shared/currency.{Crypto, Fiat}
import shared/rates/rate_request.{RateRequest}
import shared/rates/rate_response.{CoinMarketCap, Kraken}
import shared/subscriptions/subscription_id

pub fn subscribe_subscribes_to_kraken_and_returns_rate_response_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { Nil },
      unsubscribe: fn(_) { Nil },
      check_for_price: fn(_) { Ok(PriceEntry(100_000.0, 100)) },
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

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))
  subscriber.stop(target)

  // assert
  let assert Ok(#(received_sub_id, Ok(rate_response))) =
    process.receive(subject, 1000)

  assert sub_id == received_sub_id
  assert 1 == rate_response.from
  assert 2781 == rate_response.to
  assert Some(100_000.0) == rate_response.rate
  assert Kraken == rate_response.source
  assert 100 == rate_response.timestamp
}

pub fn subscribe_falls_back_to_cmc_when_kraken_symbol_does_not_exist_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { False }),
      subscribe: fn(_) { panic },
      unsubscribe: fn(_) { panic },
      check_for_price: fn(_) { panic },
    )

  let deps =
    Dependencies(
      currencies:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) {
        CmcConversion(
          1,
          "BTC",
          "Bitcoin",
          1.0,
          dict.insert(dict.new(), "2781", QuoteItem(Some(100_000.0))),
        )
        |> Some
        |> CmcResponse(CmcStatus(0, None), _)
        |> Ok
      },
      get_current_time_ms: fn() { 100 },
      logger: logger.new(),
    )
  let subscriber_factory = factories.create_rate_subscriber_factory(deps)

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))
  subscriber.stop(target)

  // assert
  let assert Ok(#(received_sub_id, Ok(rate_response))) =
    process.receive(subject, 1000)

  assert sub_id == received_sub_id
  assert 1 == rate_response.from
  assert 2781 == rate_response.to
  assert Some(100_000.0) == rate_response.rate
  assert CoinMarketCap == rate_response.source
  assert 100 == rate_response.timestamp
}

pub fn subscribe_falls_back_to_cmc_when_price_not_found_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { Nil },
      unsubscribe: fn(_) { Nil },
      check_for_price: fn(_) { Error(Nil) },
    )

  let deps =
    Dependencies(
      currencies:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) {
        CmcConversion(
          1,
          "BTC",
          "Bitcoin",
          1.0,
          dict.insert(dict.new(), "2781", QuoteItem(Some(100_000.0))),
        )
        |> Some
        |> CmcResponse(CmcStatus(0, None), _)
        |> Ok
      },
      get_current_time_ms: fn() { 100 },
      logger: logger.new(),
    )
  let subscriber_factory = factories.create_rate_subscriber_factory(deps)

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))
  subscriber.stop(target)

  // assert
  let assert Ok(#(received_sub_id, Ok(rate_response))) =
    process.receive(subject, 1000)

  assert sub_id == received_sub_id
  assert 1 == rate_response.from
  assert 2781 == rate_response.to
  assert Some(100_000.0) == rate_response.rate
  assert CoinMarketCap == rate_response.source
  assert 100 == rate_response.timestamp
}

pub fn subscribe_returns_error_when_currency_id_not_found_test() {
  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { panic },
      unsubscribe: fn(_) { panic },
      check_for_price: fn(_) { panic },
    )

  let deps =
    Dependencies(
      currencies: [Crypto(1, "Bitcoin", "BTC", Some(1))],
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) { panic },
      get_current_time_ms: fn() { panic },
      logger: logger.new(),
    )
  let subscriber_factory = factories.create_rate_subscriber_factory(deps)

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  let rate_req = RateRequest(1, 2)

  // act
  subscriber.subscribe(target, rate_req)
  subscriber.stop(target)

  // assert
  let assert Ok(#(received_sub_id, Error(rate_err))) =
    process.receive(subject, 1000)

  assert sub_id == received_sub_id
  assert CurrencyNotFound(rate_req, 2) == rate_err
}

pub fn subscribe_returns_error_when_both_sources_fail_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { False }),
      subscribe: fn(_) { panic },
      unsubscribe: fn(_) { panic },
      check_for_price: fn(_) { panic },
    )

  let deps =
    Dependencies(
      currencies:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) {
        None
        |> CmcResponse(CmcStatus(1001, Some("error")), _)
        |> Ok
      },
      get_current_time_ms: fn() { 100 },
      logger: logger.new(),
    )
  let subscriber_factory = factories.create_rate_subscriber_factory(deps)

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))
  subscriber.stop(target)

  // assert
  let assert Ok(#(received_sub_id, Error(rate_err))) =
    process.receive(subject, 1000)

  assert sub_id == received_sub_id
  let assert CmcError(RateRequest(1, 2781), _) = rate_err
}

pub fn subscribe_schedules_get_latest_rate_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { Nil },
      unsubscribe: fn(_) { Nil },
      check_for_price: fn(_) { Ok(PriceEntry(100_000.0, 100)) },
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

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))

  // assert
  let assert Ok(_) = process.receive(subject, 1000)

  let assert Ok(#(received_sub_id, Ok(rate_response))) =
    process.receive(subject, 1500)

  assert sub_id == received_sub_id
  assert 1 == rate_response.from
  assert 2781 == rate_response.to
  assert Some(100_000.0) == rate_response.rate
  assert Kraken == rate_response.source
  assert 100 == rate_response.timestamp

  subscriber.stop(target)
}

pub fn scheduled_update_returns_result_for_most_recent_request_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(1027, "Ethereum", "ETH", Some(2)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { Nil },
      unsubscribe: fn(_) { Nil },
      check_for_price: fn(symbol) {
        case kraken_symbol.to_string(symbol) {
          "BTC/USD" -> Ok(PriceEntry(100_000.0, 100))
          "ETH/USD" -> Ok(PriceEntry(4000.0, 100))
          _ -> panic
        }
      },
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

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))
  subscriber.subscribe(target, RateRequest(1027, 2781))

  // assert 
  let assert Ok(#(received_sub_id, Ok(rate_response))) =
    process.receive(subject, 1500)

  assert sub_id == received_sub_id
  assert 1 == rate_response.from
  assert 2781 == rate_response.to

  let assert Ok(#(received_sub_id, Ok(rate_response))) =
    process.receive(subject, 1500)

  assert sub_id == received_sub_id
  assert 1027 == rate_response.from
  assert 2781 == rate_response.to
  assert Some(4000.0) == rate_response.rate

  subscriber.stop(target)
}

pub fn scheduled_update_downgrades_from_kraken_to_cmc_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { Nil },
      unsubscribe: fn(_) { Nil },
      check_for_price: fn(_symbol) {
        case get_and_increment("call_count") {
          0 -> Ok(PriceEntry(100_000.0, 100))
          _ -> Error(Nil)
        }
      },
    )

  let deps =
    Dependencies(
      currencies:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) {
        CmcConversion(
          1,
          "BTC",
          "Bitcoin",
          1.0,
          dict.insert(dict.new(), "2781", QuoteItem(Some(100_001.0))),
        )
        |> Some
        |> CmcResponse(CmcStatus(0, None), _)
        |> Ok
      },
      get_current_time_ms: fn() { 1000 },
      logger: logger.new(),
    )
  let subscriber_factory = factories.create_rate_subscriber_factory(deps)

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))

  // assert
  let assert Ok(#(_, Ok(rate_response))) = process.receive(subject, 1000)

  assert Kraken == rate_response.source
  assert Some(100_000.0) == rate_response.rate

  let assert Ok(#(_, Ok(rate_response))) = process.receive(subject, 1500)

  assert CoinMarketCap == rate_response.source
  assert Some(100_001.0) == rate_response.rate
}

pub fn add_currencies_enables_subscription_to_previously_unknown_currency_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let currency_to_add = Crypto(22_354, "QUAI", "QUAI Network", None)

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { Nil },
      unsubscribe: fn(_) { Nil },
      check_for_price: fn(_) { Error(Nil) },
    )

  let deps =
    Dependencies(
      currencies:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) {
        CmcConversion(
          currency_to_add.id,
          currency_to_add.symbol,
          currency_to_add.name,
          1.0,
          dict.insert(dict.new(), "2781", QuoteItem(Some(0.05))),
        )
        |> Some
        |> CmcResponse(CmcStatus(0, None), _)
        |> Ok
      },
      get_current_time_ms: fn() { 1000 },
      logger: logger.new(),
    )
  let subscriber_factory = factories.create_rate_subscriber_factory(deps)

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  let rate_request = RateRequest(currency_to_add.id, 2781)

  subscriber.subscribe(target, rate_request)

  // assert initial attempt returns CurrencyNotFound
  let assert Ok(#(_, Error(rate_err))) = process.receive(subject, 1000)
  assert CurrencyNotFound(rate_request, currency_to_add.id) == rate_err

  // act
  subscriber.add_currencies(target, [currency_to_add])

  // assert second attempt succeeds now that the currency has now beed added
  subscriber.subscribe(target, rate_request)

  let assert Ok(#(_, Ok(rate_response))) = process.receive(subject, 1000)
  assert currency_to_add.id == rate_response.from

  subscriber.stop(target)
}

pub fn stop_unsubscribes_from_kraken_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let unsub_subject = process.new_subject()

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { Nil },
      unsubscribe: fn(_) { process.send(unsub_subject, True) },
      check_for_price: fn(_) { Ok(PriceEntry(100_000.0, 100)) },
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

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  subscriber.subscribe(target, RateRequest(1, 2781))

  let assert Ok(#(_, Ok(_))) = process.receive(subject, 1000)

  // act 
  subscriber.stop(target)

  //assert
  let assert Ok(True) = process.receive(unsub_subject, 1000)
}

/// Gets the current value of the counter and increments it using the process dictionary.
/// Returns the value BEFORE incrementing (0 on first call, 1 on second, etc.)
/// 
/// **Important**: This function uses Erlang's process dictionary, so the counter
/// state is local to the calling process. Calls from different processes will
/// maintain separate counter instances.
fn get_and_increment(counter_name: String) -> Int {
  let key = atom.create(counter_name)
  let current = get_or_zero(key)
  let _ = put_and_return_previous(key, current + 1)

  current
}

@external(erlang, "counter_ffi", "get_or_zero")
fn get_or_zero(key: Atom) -> Int

@external(erlang, "counter_ffi", "put_and_return_previous")
fn put_and_return_previous(key: Atom, value: Int) -> Int
