import exception
import gleam/dict
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{None, Some}
import server/currencies/currency_repository.{CurrencyRepository}
import server/currencies/currency_symbol_cache
import server/dependencies.{type Dependencies, Dependencies}
import server/integrations/coin_market_cap/client.{CmcResponse, CmcStatus}
import server/integrations/coin_market_cap/cmc_conversion.{
  CmcConversion, QuoteItem,
}
import server/integrations/kraken/price_store.{PriceEntry}
import server/rates/internal/kraken_interface.{KrakenInterface}
import server/rates/internal/kraken_symbol
import server/rates/internal/subscription_manager
import server/rates/rate_error.{CmcError, CurrencyNotFound}
import server/rates/subscriber.{type RateSubscriber, type SubscriptionResult}
import server/rates/subscriber_factory
import server/utils/logger
import shared/currency.{Crypto, Fiat}
import shared/numbers/positive_float
import shared/rates/rate_request.{type RateRequest, RateRequest}
import shared/rates/rate_response.{type Source, CoinMarketCap, Kraken}
import shared/subscriptions/subscription_id

type ScheduledUpdate {
  ScheduledUpdate(delay_ms: Int, deliver: fn() -> Nil)
}

fn record_schedule(updates: Subject(ScheduledUpdate)) -> subscriber.Scheduler {
  fn(delay, deliver) { process.send(updates, ScheduledUpdate(delay, deliver)) }
}

fn await_scheduled_update(updates, expected_delay) {
  let assert Ok(ScheduledUpdate(delay, deliver)) =
    process.receive(updates, 1000)
  assert delay == expected_delay
  deliver
}

fn scheduled_subscriber_factory(deps: Dependencies, updates) {
  fn(id, reply_to) {
    let assert Ok(manager) =
      subscription_manager.new(deps.subscription_refresh_interval_ms)
    let assert Ok(target) =
      subscriber.new_with_scheduler(
        id,
        reply_to,
        subscriber.Config(
          get_currency: deps.currency_repository.get_by_id,
          kraken_interface: deps.kraken_interface,
          request_cmc_conversion: deps.request_cmc_conversion,
          subscription_manager: manager,
          logger: deps.logger,
        ),
        record_schedule(updates),
      )
    target
  }
}

pub fn subscribe_subscribes_to_kraken_and_returns_rate_response_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(id) {
        list.find(currencies, fn(currency) { currency.id == id })
      },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { panic },
    )

  let expected_price = positive_float.from_float_unsafe(100_000.0)
  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { Nil },
      unsubscribe: fn(_) { Nil },
      check_for_price: fn(_) { Ok(PriceEntry(expected_price, 100)) },
    )

  let assert Ok(currency_symbol_cache) =
    currency_symbol_cache.new(fn(_) { panic }, fn(_) { panic })

  let deps =
    Dependencies(
      currency_repository:,
      currency_symbol_cache:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) { panic },
      logger: logger.new(),
    )
  let subscriber_factory = subscriber_factory.create(deps)

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))
  subscriber.stop(target)

  // assert
  let assert Ok(#(received_sub_id, Ok(rate_response))) =
    process.receive(subject, 1000)

  assert received_sub_id == sub_id
  assert rate_response.from == 1
  assert rate_response.to == 2781
  assert rate_response.rate == Some(expected_price)
  assert rate_response.source == Kraken
  assert rate_response.timestamp == 100
}

pub fn subscribe_falls_back_to_cmc_when_kraken_symbol_does_not_exist_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(id) {
        list.find(currencies, fn(currency) { currency.id == id })
      },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { panic },
    )

  let assert Ok(currency_symbol_cache) =
    currency_symbol_cache.new(fn(_) { panic }, fn(_) { panic })

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { False }),
      subscribe: fn(_) { panic },
      unsubscribe: fn(_) { panic },
      check_for_price: fn(_) { panic },
    )

  let expected_price = positive_float.from_float_unsafe(100_000.0)
  let deps =
    Dependencies(
      currency_repository:,
      currency_symbol_cache:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) {
        CmcConversion(
          1,
          "BTC",
          "Bitcoin",
          positive_float.from_float_unsafe(1.0),
          dict.insert(dict.new(), "2781", QuoteItem(Some(expected_price), 100)),
        )
        |> Some
        |> CmcResponse(CmcStatus(0, None), _)
        |> Ok
      },
      logger: logger.new(),
    )
  let subscriber_factory = subscriber_factory.create(deps)

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))
  subscriber.stop(target)

  // assert
  let assert Ok(#(received_sub_id, Ok(rate_response))) =
    process.receive(subject, 1000)

  assert received_sub_id == sub_id
  assert rate_response.from == 1
  assert rate_response.to == 2781
  assert rate_response.rate == Some(expected_price)
  assert rate_response.source == CoinMarketCap
  assert rate_response.timestamp == 100
}

pub fn subscribe_falls_back_to_cmc_when_price_not_found_test() {
  let interest = process.new_subject()
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]
  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(id) {
        list.find(currencies, fn(currency) { currency.id == id })
      },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { panic },
    )

  let assert Ok(currency_symbol_cache) =
    currency_symbol_cache.new(fn(_) { panic }, fn(_) { panic })

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { process.send(interest, #(True, process.self())) },
      unsubscribe: fn(_) { process.send(interest, #(False, process.self())) },
      check_for_price: fn(_) { Error(Nil) },
    )

  let expected_price = positive_float.from_float_unsafe(100_000.0)
  let deps =
    Dependencies(
      currency_repository:,
      currency_symbol_cache:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) {
        CmcConversion(
          1,
          "BTC",
          "Bitcoin",
          positive_float.from_float_unsafe(1.0),
          dict.insert(dict.new(), "2781", QuoteItem(Some(expected_price), 100)),
        )
        |> Some
        |> CmcResponse(CmcStatus(0, None), _)
        |> Ok
      },
      logger: logger.new(),
    )
  let subscriber_factory = subscriber_factory.create(deps)

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))
  subscriber.stop(target)

  // assert
  let assert Ok(#(received_sub_id, Ok(rate_response))) =
    process.receive(subject, 1000)

  assert received_sub_id == sub_id
  assert rate_response.from == 1
  assert rate_response.to == 2781
  assert rate_response.rate == Some(expected_price)
  assert rate_response.source == CoinMarketCap
  assert rate_response.timestamp == 100

  let assert Ok(#(True, pid)) = process.receive(interest, 1000)
  let assert Ok(#(False, _)) = process.receive(interest, 1000)
  let monitor = process.monitor(pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  assert process.receive(interest, 0) == Error(Nil)
}

pub fn cmc_fallback_recovers_to_kraken_and_restores_refresh_interval_test() {
  let interest = process.new_subject()
  let subject = process.new_subject()
  let updates = process.new_subject()
  let kraken_price = positive_float.from_float_unsafe(100_000.0)
  let cmc_price = positive_float.from_float_unsafe(100_001.0)
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]
  let interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) {
        process.send(interest, #("subscribe", process.self()))
      },
      unsubscribe: fn(_) {
        process.send(interest, #("unsubscribe", process.self()))
      },
      check_for_price: fn(_) {
        case get_and_increment("recovery_price_lookups") {
          0 -> Error(Nil)
          _ -> Ok(PriceEntry(kraken_price, 200))
        }
      },
    )
  let assert Ok(manager) = subscription_manager.new(1000)
  let assert Ok(id) = subscription_id.new("recovering")
  let assert Ok(target) =
    subscriber.new_with_scheduler(
      id,
      subject,
      subscriber.Config(
        get_currency: fn(id) {
          list.find(currencies, fn(currency) { currency.id == id })
        },
        kraken_interface: interface,
        request_cmc_conversion: fn(_) {
          CmcConversion(
            1,
            "BTC",
            "Bitcoin",
            positive_float.from_float_unsafe(1.0),
            dict.insert(dict.new(), "2781", QuoteItem(Some(cmc_price), 100)),
          )
          |> Some
          |> CmcResponse(CmcStatus(0, None), _)
          |> Ok
        },
        subscription_manager: manager,
        logger: logger.new(),
      ),
      record_schedule(updates),
    )
  use <- exception.defer(fn() { subscriber.stop(target) })
  subscriber.subscribe(target, RateRequest(1, 2781))
  let assert Ok(#("subscribe", pid)) = process.receive(interest, 1000)
  let monitor = process.monitor(pid)
  let assert Ok(#(_, Ok(initial))) = process.receive(subject, 1000)
  assert initial.source == CoinMarketCap
  assert initial.rate == Some(cmc_price)
  assert process.receive(interest, 1000) == Ok(#("unsubscribe", pid))

  // Verify the CMC interval, then deliver the scheduled update immediately.
  let recover = await_scheduled_update(updates, 30_000)
  recover()
  let assert Ok(#(_, Ok(recovered))) = process.receive(subject, 1000)
  assert recovered.source == Kraken
  assert recovered.rate == Some(kraken_price)
  assert recovered.timestamp == 200
  assert process.receive(interest, 1000) == Ok(#("subscribe", pid))

  // Recovery retains interest and restores the requested Kraken interval.
  let refresh = await_scheduled_update(updates, 1000)
  refresh()
  let assert Ok(#(_, Ok(next))) = process.receive(subject, 1000)
  assert next.source == Kraken
  assert process.receive(interest, 0) == Error(Nil)
  subscriber.stop(target)
  assert process.receive(interest, 1000) == Ok(#("unsubscribe", pid))
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  assert process.receive(interest, 0) == Error(Nil)
}

pub fn subscribe_returns_error_when_currency_id_not_found_test() {
  let currencies = [Crypto(1, "Bitcoin", "BTC", Some(1))]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(id) {
        list.find(currencies, fn(currency) { currency.id == id })
      },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { panic },
    )

  let assert Ok(currency_symbol_cache) =
    currency_symbol_cache.new(fn(_) { panic }, fn(_) { panic })

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { panic },
      unsubscribe: fn(_) { panic },
      check_for_price: fn(_) { panic },
    )

  let deps =
    Dependencies(
      currency_repository:,
      currency_symbol_cache:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) { panic },
      logger: logger.new(),
    )
  let subscriber_factory = subscriber_factory.create(deps)

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

  assert received_sub_id == sub_id
  assert rate_err == CurrencyNotFound(rate_req, 2)
}

pub fn subscribe_returns_error_when_both_sources_fail_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]
  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(id) {
        list.find(currencies, fn(currency) { currency.id == id })
      },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { panic },
    )

  let assert Ok(currency_symbol_cache) =
    currency_symbol_cache.new(fn(_) { panic }, fn(_) { panic })

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { False }),
      subscribe: fn(_) { panic },
      unsubscribe: fn(_) { panic },
      check_for_price: fn(_) { panic },
    )

  let deps =
    Dependencies(
      currency_repository:,
      currency_symbol_cache:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) {
        None
        |> CmcResponse(CmcStatus(1001, Some("error")), _)
        |> Ok
      },
      logger: logger.new(),
    )
  let subscriber_factory = subscriber_factory.create(deps)

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))
  subscriber.stop(target)

  // assert
  let assert Ok(#(received_sub_id, Error(rate_err))) =
    process.receive(subject, 1000)

  assert received_sub_id == sub_id
  let assert CmcError(RateRequest(1, 2781), _) = rate_err
}

pub fn subscribe_schedules_get_latest_rate_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(id) {
        list.find(currencies, fn(currency) { currency.id == id })
      },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { panic },
    )

  let assert Ok(currency_symbol_cache) =
    currency_symbol_cache.new(fn(_) { panic }, fn(_) { panic })

  let expected_price = positive_float.from_float_unsafe(100_000.0)
  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { Nil },
      unsubscribe: fn(_) { Nil },
      check_for_price: fn(_) { Ok(PriceEntry(expected_price, 100)) },
    )

  let deps =
    Dependencies(
      currency_repository:,
      currency_symbol_cache:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) { panic },
      logger: logger.new(),
    )
  let updates = process.new_subject()
  let subscriber_factory = scheduled_subscriber_factory(deps, updates)

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)
  use <- exception.defer(fn() { subscriber.stop(target) })

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))

  // assert
  let assert Ok(_) = process.receive(subject, 1000)
  let refresh = await_scheduled_update(updates, 1000)
  refresh()

  let assert Ok(#(received_sub_id, Ok(rate_response))) =
    process.receive(subject, 1500)

  assert received_sub_id == sub_id
  assert rate_response.from == 1
  assert rate_response.to == 2781
  assert rate_response.rate == Some(expected_price)
  assert rate_response.source == Kraken
  assert rate_response.timestamp == 100

  subscriber.stop(target)
}

pub fn scheduled_update_returns_result_for_most_recent_request_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(1027, "Ethereum", "ETH", Some(2)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(id) {
        list.find(currencies, fn(currency) { currency.id == id })
      },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { panic },
    )

  let assert Ok(currency_symbol_cache) =
    currency_symbol_cache.new(fn(_) { panic }, fn(_) { panic })

  let expected_price = positive_float.from_float_unsafe(4000.0)
  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { Nil },
      unsubscribe: fn(_) { Nil },
      check_for_price: fn(symbol) {
        case kraken_symbol.to_string(symbol) {
          "BTC/USD" ->
            Ok(PriceEntry(positive_float.from_float_unsafe(100_000.0), 100))
          "ETH/USD" -> Ok(PriceEntry(expected_price, 100))
          _ -> panic
        }
      },
    )

  let deps =
    Dependencies(
      currency_repository:,
      currency_symbol_cache:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) { panic },
      logger: logger.new(),
    )
  let updates = process.new_subject()
  let subscriber_factory = scheduled_subscriber_factory(deps, updates)

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)
  use <- exception.defer(fn() { subscriber.stop(target) })

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))
  subscriber.subscribe(target, RateRequest(1027, 2781))

  // assert 
  let assert Ok(#(received_sub_id, Ok(rate_response))) =
    process.receive(subject, 1500)

  assert received_sub_id == sub_id
  assert rate_response.from == 1
  assert rate_response.to == 2781
  let old_refresh = await_scheduled_update(updates, 1000)

  let assert Ok(#(received_sub_id, Ok(rate_response))) =
    process.receive(subject, 1500)

  assert received_sub_id == sub_id
  assert rate_response.from == 1027
  assert rate_response.to == 2781
  assert rate_response.rate == Some(expected_price)

  let current_refresh = await_scheduled_update(updates, 1000)
  old_refresh()
  current_refresh()
  let assert Ok(#(_, Ok(latest))) = process.receive(subject, 1000)
  assert latest.from == 1027
  assert latest.rate == Some(expected_price)
  assert process.receive(subject, 0) == Error(Nil)
  let _ = await_scheduled_update(updates, 1000)
  assert process.receive(updates, 0) == Error(Nil)

  subscriber.stop(target)
}

pub fn repeated_kraken_subscription_ignores_stale_refresh_test() {
  assert_repeated_subscription_ignores_stale_refresh(Kraken)
}

pub fn repeated_cmc_subscription_ignores_stale_refresh_test() {
  assert_repeated_subscription_ignores_stale_refresh(CoinMarketCap)
}

fn assert_repeated_subscription_ignores_stale_refresh(source) {
  let fixture = new_refresh_test(source)
  use <- exception.defer(fn() { subscriber.stop(fixture.target) })
  let request = RateRequest(1, 2781)
  let old_refresh = subscribe_and_capture_refresh(fixture, request)
  let current_refresh = subscribe_and_capture_refresh(fixture, request)

  old_refresh()
  current_refresh()
  stop_refresh_test(fixture)

  let _ = await_refresh(fixture, request)
  assert_no_refresh_activity(fixture)
}

pub fn returning_to_previous_pair_ignores_stale_refreshes_test() {
  let fixture = new_refresh_test(Kraken)
  use <- exception.defer(fn() { subscriber.stop(fixture.target) })
  let request = RateRequest(1, 2781)
  let first_refresh = subscribe_and_capture_refresh(fixture, request)
  let other_refresh =
    subscribe_and_capture_refresh(fixture, RateRequest(1027, 2781))
  let current_refresh = subscribe_and_capture_refresh(fixture, request)

  first_refresh()
  other_refresh()
  current_refresh()
  stop_refresh_test(fixture)

  let _ = await_refresh(fixture, request)
  assert_no_refresh_activity(fixture)
}

pub fn scheduled_refresh_callback_can_only_be_consumed_once_test() {
  let fixture = new_refresh_test(Kraken)
  use <- exception.defer(fn() { subscriber.stop(fixture.target) })
  let request = RateRequest(1, 2781)
  let refresh = subscribe_and_capture_refresh(fixture, request)

  refresh()
  refresh()
  let next_refresh = await_refresh(fixture, request)

  // Replaying a consumed callback must also be harmless after its successor
  // has been scheduled, while the successor must still be accepted.
  refresh()
  next_refresh()
  stop_refresh_test(fixture)

  let _ = await_refresh(fixture, request)
  assert_no_refresh_activity(fixture)
}

pub fn invalid_request_invalidates_pending_kraken_refresh_test() {
  assert_invalid_request_invalidates_pending_refresh(Kraken)
}

pub fn invalid_request_invalidates_pending_cmc_refresh_test() {
  assert_invalid_request_invalidates_pending_refresh(CoinMarketCap)
}

fn assert_invalid_request_invalidates_pending_refresh(source) {
  let fixture = new_refresh_test(source)
  use <- exception.defer(fn() { subscriber.stop(fixture.target) })
  let old_refresh = subscribe_and_capture_refresh(fixture, RateRequest(1, 2781))
  let invalid_request = RateRequest(1, 999)

  subscriber.subscribe(fixture.target, invalid_request)
  old_refresh()
  stop_refresh_test(fixture)

  let assert Ok(#(_, Error(error))) = process.receive(fixture.replies, 1000)
  assert error == CurrencyNotFound(invalid_request, 999)
  assert_no_refresh_activity(fixture)
}

pub fn scheduled_update_downgrades_from_kraken_to_cmc_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(id) {
        list.find(currencies, fn(currency) { currency.id == id })
      },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { panic },
    )

  let assert Ok(currency_symbol_cache) =
    currency_symbol_cache.new(fn(_) { panic }, fn(_) { panic })

  let expected_kraken_price = positive_float.from_float_unsafe(100_000.0)
  let expected_cmc_price = positive_float.from_float_unsafe(100_001.0)

  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { Nil },
      unsubscribe: fn(_) { Nil },
      check_for_price: fn(_symbol) {
        case get_and_increment("call_count") {
          0 -> Ok(PriceEntry(expected_kraken_price, 100))
          _ -> Error(Nil)
        }
      },
    )

  let deps =
    Dependencies(
      currency_repository:,
      currency_symbol_cache:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) {
        CmcConversion(
          1,
          "BTC",
          "Bitcoin",
          positive_float.from_float_unsafe(1.0),
          dict.insert(
            dict.new(),
            "2781",
            QuoteItem(Some(expected_cmc_price), 1000),
          ),
        )
        |> Some
        |> CmcResponse(CmcStatus(0, None), _)
        |> Ok
      },
      logger: logger.new(),
    )
  let updates = process.new_subject()
  let subscriber_factory = scheduled_subscriber_factory(deps, updates)

  let assert Ok(sub_id) = subscription_id.new("1")
  let subject = process.new_subject()
  let target = subscriber_factory(sub_id, subject)
  use <- exception.defer(fn() { subscriber.stop(target) })

  // act
  subscriber.subscribe(target, RateRequest(1, 2781))

  // assert
  let assert Ok(#(_, Ok(rate_response))) = process.receive(subject, 1000)

  assert rate_response.source == Kraken
  assert rate_response.rate == Some(expected_kraken_price)

  let refresh = await_scheduled_update(updates, 1000)
  refresh()

  let assert Ok(#(_, Ok(rate_response))) = process.receive(subject, 1500)

  assert rate_response.source == CoinMarketCap
  assert rate_response.rate == Some(expected_cmc_price)
  let _ = await_scheduled_update(updates, 30_000)
}

pub fn stop_unsubscribes_from_kraken_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let currency_repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(id) {
        list.find(currencies, fn(currency) { currency.id == id })
      },
      get_by_symbol: fn(_) { panic },
      get_all: fn() { panic },
    )

  let assert Ok(currency_symbol_cache) =
    currency_symbol_cache.new(fn(_) { panic }, fn(_) { panic })

  let unsub_subject = process.new_subject()
  let kraken_interface =
    KrakenInterface(
      get_kraken_symbol: kraken_symbol.new(_, fn(_) { True }),
      subscribe: fn(_) { Nil },
      unsubscribe: fn(_) { process.send(unsub_subject, True) },
      check_for_price: fn(_) {
        Ok(PriceEntry(positive_float.from_float_unsafe(100_000.0), 100))
      },
    )

  let deps =
    Dependencies(
      currency_repository:,
      currency_symbol_cache:,
      subscription_refresh_interval_ms: 1000,
      kraken_interface:,
      request_cmc_cryptos: fn(_) { panic },
      request_cmc_conversion: fn(_) { panic },
      logger: logger.new(),
    )
  let subscriber_factory = subscriber_factory.create(deps)

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

type RefreshTest {
  RefreshTest(
    target: RateSubscriber,
    replies: Subject(SubscriptionResult),
    updates: Subject(ScheduledUpdate),
    provider_calls: Subject(Source),
    actor_pids: Subject(Pid),
    source: Source,
  )
}

fn new_refresh_test(source: Source) -> RefreshTest {
  let replies = process.new_subject()
  let updates = process.new_subject()
  let provider_calls = process.new_subject()
  let actor_pids = process.new_subject()
  let price = positive_float.from_float_unsafe(100_000.0)
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(1027, "Ethereum", "ETH", Some(2)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]
  let assert Ok(manager) = subscription_manager.new(1000)
  let assert Ok(id) = subscription_id.new("refresh-test")
  let assert Ok(target) =
    subscriber.new_with_scheduler(
      id,
      replies,
      subscriber.Config(
        get_currency: fn(id) {
          process.send(actor_pids, process.self())
          list.find(currencies, fn(currency) { currency.id == id })
        },
        kraken_interface: KrakenInterface(
          get_kraken_symbol: kraken_symbol.new(_, fn(_) { source == Kraken }),
          subscribe: fn(_) { Nil },
          unsubscribe: fn(_) { Nil },
          check_for_price: fn(_) {
            process.send(provider_calls, Kraken)
            Ok(PriceEntry(price, 100))
          },
        ),
        request_cmc_conversion: fn(parameters) {
          process.send(provider_calls, CoinMarketCap)
          CmcConversion(
            parameters.id,
            "BTC",
            "Bitcoin",
            positive_float.from_float_unsafe(1.0),
            dict.insert(dict.new(), "2781", QuoteItem(Some(price), 100)),
          )
          |> Some
          |> CmcResponse(CmcStatus(0, None), _)
          |> Ok
        },
        subscription_manager: manager,
        logger: logger.new(),
      ),
      record_schedule(updates),
    )
  RefreshTest(target, replies, updates, provider_calls, actor_pids, source)
}

fn subscribe_and_capture_refresh(fixture: RefreshTest, request: RateRequest) {
  subscriber.subscribe(fixture.target, request)
  await_refresh(fixture, request)
}

fn await_refresh(fixture: RefreshTest, request: RateRequest) -> fn() -> Nil {
  let assert Ok(#(_, Ok(response))) = process.receive(fixture.replies, 1000)
  assert response.from == request.from
  assert response.to == request.to
  assert response.source == fixture.source
  assert process.receive(fixture.provider_calls, 1000) == Ok(fixture.source)
  let interval = case fixture.source {
    Kraken -> 1000
    CoinMarketCap -> 30_000
  }
  await_scheduled_update(fixture.updates, interval)
}

fn stop_refresh_test(fixture: RefreshTest) -> Nil {
  let assert Ok(pid) = process.receive(fixture.actor_pids, 1000)
  let monitor = process.monitor(pid)
  // Deliveries and Stop come from this test process, so observing termination
  // ensures all queued deliveries were handled before checking for extras.
  subscriber.stop(fixture.target)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  Nil
}

fn assert_no_refresh_activity(fixture: RefreshTest) -> Nil {
  assert process.receive(fixture.replies, 0) == Error(Nil)
  assert process.receive(fixture.provider_calls, 0) == Error(Nil)
  assert process.receive(fixture.updates, 0) == Error(Nil)
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
