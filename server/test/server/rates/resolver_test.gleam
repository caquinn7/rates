import exception
import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import server/currencies/currency_repository.{CurrencyRepository}
import server/integrations/coin_market_cap/client.{
  CmcResponse, CmcStatus, HttpError,
}
import server/integrations/coin_market_cap/cmc_conversion.{
  CmcConversion, QuoteItem,
}
import server/integrations/kraken/price_store.{PriceEntry}
import server/rates/internal/cmc_rate_handler.{
  type RequestCmcConversion, RequestFailed,
}
import server/rates/internal/kraken_interface.{
  type KrakenInterface, KrakenInterface,
}
import server/rates/internal/kraken_symbol
import server/rates/rate_error.{CmcError, CurrencyNotFound, TimedOut}
import server/rates/rate_service_config.{RateServiceConfig}
import server/rates/resolver
import server/utils/time
import server/web/routes/home
import shared/client_state.{ClientState, ConverterState}
import shared/currency.{type Currency, Crypto, Fiat}
import shared/numbers/positive_float
import shared/page_data
import shared/rates/rate_request.{RateRequest}
import shared/rates/rate_response.{CoinMarketCap, Kraken, RateResponse}
import wisp

type Event {
  Worker(Pid)
  Subscribed(Pid)
  Unsubscribed
}

pub fn kraken_success_releases_interest_and_preserves_quote_test() {
  let events = process.new_subject()
  let config =
    config(
      kraken(events, True, fn(_) {
        process.send(events, Worker(process.self()))
        Ok(PriceEntry(price(), 123))
      }),
      fn(_) { panic as "CMC must not run for a Kraken quote" },
    )
  use target, controller <- with_resolver(config)
  assert resolver.get_rate(target, RateRequest(1, 2781), 1000)
    == Ok(RateResponse(1, 2781, Some(price()), Kraken, 123))
  await_dead(controller)
  assert_worker_stopped_and_interest_released(events, controller)
}

pub fn fallback_success_releases_interest_exactly_once_test() {
  let events = process.new_subject()
  let config =
    config(kraken(events, True, fn(_) { Error(Nil) }), fn(params) {
      process.send(events, Worker(process.self()))
      cmc_quote(params.id)
    })
  use target, controller <- with_resolver(config)
  assert resolver.get_rate(target, RateRequest(1, 2781), 1000)
    == Ok(RateResponse(1, 2781, Some(price()), CoinMarketCap, 456))
  await_dead(controller)
  assert_worker_stopped_and_interest_released(events, controller)
}

pub fn cmc_only_success_does_not_acquire_kraken_interest_test() {
  let events = process.new_subject()
  use target, controller <- with_resolver(
    config(kraken(events, False, fn(_) { panic }), fn(params) {
      cmc_quote(params.id)
    }),
  )
  assert resolver.get_rate(target, RateRequest(1, 2781), 1000)
    == Ok(RateResponse(1, 2781, Some(price()), CoinMarketCap, 456))
  await_dead(controller)
  assert drain(events) == []
}

pub fn missing_currency_remains_a_currency_error_test() {
  let events = process.new_subject()
  use target, controller <- with_resolver(
    config(kraken(events, False, fn(_) { panic }), fn(_) { panic }),
  )
  assert resolver.get_rate(target, RateRequest(999, 2781), 1000)
    == Error(CurrencyNotFound(RateRequest(999, 2781), 999))
  await_dead(controller)
  assert drain(events) == []
}

pub fn provider_response_timeout_keeps_its_original_error_test() {
  let events = process.new_subject()
  use target, controller <- with_resolver(
    config(kraken(events, False, fn(_) { panic }), fn(_) {
      Error(HttpError(httpc.ResponseTimeout))
    }),
  )
  assert resolver.get_rate(target, RateRequest(1, 2781), 1000)
    == Error(CmcError(
      RateRequest(1, 2781),
      RequestFailed(HttpError(httpc.ResponseTimeout)),
    ))
  await_dead(controller)
}

pub fn blocked_cmc_times_out_stops_worker_and_allows_another_lookup_test() {
  let events = process.new_subject()
  let before_monitors = monitored_processes(process.self())
  use target, controller <- with_resolver(
    config(kraken(events, False, fn(_) { panic }), fn(_) { block(events) }),
  )
  let start = time.monotonic_time_ms()
  assert resolver.get_rate(target, RateRequest(1, 2781), 75)
    == Error(TimedOut(RateRequest(1, 2781)))
  assert time.monotonic_time_ms() - start < 1000
  await_dead(controller)
  let assert [Worker(worker)] = drain(events)
  assert !process.is_alive(worker)
  assert monitored_processes(process.self()) == before_monitors

  use next, next_controller <- with_resolver(
    config(kraken(events, False, fn(_) { panic }), fn(params) {
      cmc_quote(params.id)
    }),
  )
  let assert Ok(_) = resolver.get_rate(next, RateRequest(1, 2781), 1000)
  await_dead(next_controller)
}

pub fn timeout_during_kraken_polling_releases_interest_test() {
  let events = process.new_subject()
  use target, controller <- with_resolver(
    config(kraken(events, True, fn(_) { block(events) }), fn(_) { panic }),
  )
  assert resolver.get_rate(target, RateRequest(1, 2781), 75)
    == Error(TimedOut(RateRequest(1, 2781)))
  await_dead(controller)
  assert_worker_stopped_and_interest_released(events, controller)
}

pub fn timeout_during_fallback_does_not_release_interest_twice_test() {
  let events = process.new_subject()
  use target, controller <- with_resolver(
    config(kraken(events, True, fn(_) { Error(Nil) }), fn(_) { block(events) }),
  )
  assert resolver.get_rate(target, RateRequest(1, 2781), 75)
    == Error(TimedOut(RateRequest(1, 2781)))
  await_dead(controller)
  assert_worker_stopped_and_interest_released(events, controller)
}

pub fn deadline_also_bounds_strategy_selection_test() {
  let events = process.new_subject()
  let original = config(kraken(events, False, fn(_) { panic }), fn(_) { panic })
  let config =
    resolver.Config(
      RateServiceConfig(..original.base, get_currency: fn(_) { block(events) }),
    )
  use target, controller <- with_resolver(config)
  assert resolver.get_rate(target, RateRequest(1, 2781), 75)
    == Error(TimedOut(RateRequest(1, 2781)))
  await_dead(controller)
  let assert [Worker(worker)] = drain(events)
  assert !process.is_alive(worker)
}

pub fn nonpositive_budgets_do_not_start_lookup_work_test() {
  let events = process.new_subject()
  let original = config(kraken(events, False, fn(_) { panic }), fn(_) { panic })
  let config =
    resolver.Config(
      RateServiceConfig(..original.base, get_currency: fn(_) {
        panic as "lookup must not run"
      }),
    )
  list.each([0, -1], fn(timeout) {
    use target, controller <- with_resolver(config)
    assert resolver.get_rate(target, RateRequest(1, 2781), timeout)
      == Error(TimedOut(RateRequest(1, 2781)))
    await_dead(controller)
  })
  assert drain(events) == []
}

pub fn worker_crashes_are_not_reported_as_timeouts_test() {
  let events = process.new_subject()
  use target, controller <- with_resolver(
    config(
      kraken(events, True, fn(_) {
        process.send(events, Worker(process.self()))
        panic as "price provider exploded"
      }),
      fn(_) { panic },
    ),
  )
  let assert Error(exception.Errored(details)) =
    exception.rescue(fn() {
      resolver.get_rate(target, RateRequest(1, 2781), 1000)
    })
  assert string.contains(string.inspect(details), "price provider exploded")
  await_dead(controller)
  assert_worker_stopped_and_interest_released(events, controller)
}

pub fn owner_exit_cancels_work_and_releases_interest_test() {
  let events = process.new_subject()
  let config =
    config(kraken(events, True, fn(_) { block(events) }), fn(_) { panic })
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(target) = resolver.new(config)
      resolver.get_rate(target, RateRequest(1, 2781), 10_000)
    })
  use <- exception.defer(fn() { process.kill(owner) })
  let assert Ok(Subscribed(controller)) = process.receive(events, 1000)
  let assert Ok(Worker(worker)) = process.receive(events, 1000)
  process.kill(owner)
  await_dead(controller)
  assert !process.is_alive(worker)
  assert drain(events) == [Unsubscribed]
}

pub fn resolver_enforces_its_deadline_even_while_caller_is_suspended_test() {
  let events = process.new_subject()
  let replies = process.new_subject()
  let config =
    config(kraken(events, True, fn(_) { block(events) }), fn(_) { panic })
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(target) = resolver.new(config)
      let reply = resolver.get_rate(target, RateRequest(1, 2781), 200)
      process.send(replies, reply)
    })
  use <- exception.defer(fn() { process.kill(owner) })
  let assert Ok(Subscribed(controller)) = process.receive(events, 1000)
  let assert Ok(Worker(worker)) = process.receive(events, 1000)
  assert suspend_process(owner)

  await_dead(controller)
  assert !process.is_alive(worker)
  assert drain(events) == [Unsubscribed]

  assert resume_process(owner)
  assert process.receive(replies, 1000)
    == Ok(Error(TimedOut(RateRequest(1, 2781))))
  await_dead(owner)
}

pub fn resolver_timeout_preserves_home_converters_and_successful_quotes_test() {
  let events = process.new_subject()
  let config =
    config(kraken(events, False, fn(_) { panic }), fn(params) {
      case params.id {
        1 -> cmc_quote(1)
        _ -> block(events)
      }
    })
  let repository =
    CurrencyRepository(
      insert: fn(_) { panic },
      get_by_id: fn(_) { panic },
      get_by_symbol: fn(_) { panic },
      get_all: currencies,
    )
  let state =
    ClientState([
      ConverterState(1, 2781, 0.00000001),
      ConverterState(1027, 2781, 20.0),
    ])
  let get_rate = fn(request) {
    use target, controller <- with_resolver(config)
    let response = resolver.get_rate(target, request, 75)
    await_dead(controller)
    result.replace_error(response, Nil)
  }

  let response = home.get(repository, get_rate, Some(state))
  assert response.status == 200
  let assert wisp.Text(html) = response.body
  let assert Ok(#(_, seed_and_rest)) =
    string.split_once(html, "<script id=\"model\" type=\"application/json\">")
  let assert Ok(#(seed, _)) = string.split_once(seed_and_rest, "</script>")
  let assert Ok(data) = json.parse(seed, page_data.decoder())
  assert data.converters == state.converters
  assert data.rates
    == [RateResponse(1, 2781, Some(price()), CoinMarketCap, 456)]
  let assert [Worker(worker)] = drain(events)
  assert !process.is_alive(worker)
}

fn currencies() -> List(Currency) {
  [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(1027, "Ethereum", "ETH", Some(2)),
    Fiat(2781, "US Dollar", "USD", "$"),
  ]
}

fn config(
  kraken: KrakenInterface,
  request: RequestCmcConversion,
) -> resolver.Config {
  resolver.Config(RateServiceConfig(
    get_currency: fn(id) {
      list.find(currencies(), fn(currency) { currency.id == id })
    },
    kraken_interface: kraken,
    request_cmc_conversion: request,
  ))
}

fn kraken(events: Subject(Event), supported: Bool, check) -> KrakenInterface {
  KrakenInterface(
    get_kraken_symbol: kraken_symbol.new(_, fn(_) { supported }),
    subscribe: fn(_) { process.send(events, Subscribed(process.self())) },
    unsubscribe: fn(_) { process.send(events, Unsubscribed) },
    check_for_price: check,
  )
}

fn price() {
  positive_float.from_float_unsafe(100.0)
}

fn cmc_quote(id: Int) {
  Ok(CmcResponse(
    CmcStatus(0, None),
    Some(CmcConversion(
      id,
      "BTC",
      "Bitcoin",
      positive_float.from_float_unsafe(1.0),
      dict.from_list([#("2781", QuoteItem(Some(price()), 456))]),
    )),
  ))
}

/// Blocks until the resolver kills this worker; records its PID for cleanup assertions.
fn block(events: Subject(Event)) -> a {
  process.send(events, Worker(process.self()))
  process.sleep_forever()
  panic as "blocked worker unexpectedly resumed"
}

fn with_resolver(
  config: resolver.Config,
  run: fn(resolver.RateResolver, Pid) -> a,
) -> a {
  let previous = linked_processes(process.self())
  let assert Ok(target) = resolver.new(config)
  let assert [controller] =
    list.filter(linked_processes(process.self()), fn(pid) {
      !list.contains(previous, pid)
    })
  use <- exception.defer(fn() {
    let _ = resolver.get_rate(target, RateRequest(1, 2781), 0)
    await_dead(controller)
  })
  run(target, controller)
}

fn await_dead(pid: Pid) -> Nil {
  let monitor = process.monitor(pid)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  process.demonitor_process(monitor)
  let assert Ok(_) = down
  assert !process.is_alive(pid)
}

fn drain(events: Subject(Event)) -> List(Event) {
  case process.receive(events, 0) {
    Ok(event) -> [event, ..drain(events)]
    Error(_) -> []
  }
}

fn assert_worker_stopped_and_interest_released(
  events: Subject(Event),
  controller: Pid,
) -> Nil {
  let recorded = drain(events)
  assert list.length(recorded) == 3
  assert list.contains(recorded, Subscribed(controller))
  assert list.contains(recorded, Unsubscribed)
  let assert Ok(Worker(worker)) =
    list.find(recorded, fn(event) {
      case event {
        Worker(_) -> True
        _ -> False
      }
    })
  assert worker != controller
  assert !process.is_alive(worker)
}

/// Inspect only the test process's links and monitors; no production API is exposed.
@external(erlang, "kraken_recovery_test_ffi", "linked_processes")
fn linked_processes(pid: Pid) -> List(Pid)

@external(erlang, "kraken_recovery_test_ffi", "monitored_processes")
fn monitored_processes(pid: Pid) -> List(Pid)

/// Pause only the test caller, so the resolver must enforce its own deadline.
@external(erlang, "erlang", "suspend_process")
fn suspend_process(pid: Pid) -> Bool

@external(erlang, "erlang", "resume_process")
fn resume_process(pid: Pid) -> Bool
