import exception
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import mist
import server/integrations/coin_market_cap/client.{HttpError}
import server/integrations/kraken/client_recovery_test as fixture
import server/integrations/kraken/internal/session
import server/integrations/kraken/pairs
import server/integrations/kraken/price_store
import server/rates/internal/kraken_interface.{KrakenInterface}
import server/rates/internal/kraken_symbol
import server/rates/internal/subscription_manager
import server/rates/rate_service_config.{RateServiceConfig}
import server/rates/subscriber
import server/utils/logger
import server/utils/retry
import server/utils/time
import server/web/routes/websocket
import shared/currency.{Crypto, Fiat}
import shared/numbers/positive_float
import shared/rates/rate_request.{RateRequest}
import shared/rates/rate_response.{CoinMarketCap, RateResponse}
import shared/subscriptions/subscription_id
import shared/subscriptions/subscription_request.{SubscriptionRequest}
import shared/websocket_request
import shared/websocket_response.{
  CurrencyNotFound, ProtocolError, RateUnavailable, SubscriptionFailed,
  SubscriptionUpdate,
}
import stratus

type BrowserMessage {
  Send(String)
  Close
}

const bitcoin_id = 1

const ethereum_id = 1027

const usd_id = 2781

pub fn closing_one_browser_preserves_shared_symbol_until_last_browser_closes_test() {
  use kraken, requests <- fixture.with_kraken
  use url, subscribers <- with_application(kraken.data)
  use first, first_replies <- with_browser(url)
  use second, second_replies <- with_browser(url)

  browser_subscribe(first, [#("first", bitcoin_id)])
  let first_subscriber = unwrap(process.receive(subscribers, 1000))
  let _ = unwrap(process.receive(first_replies, 1000))

  assert await_ticker_request(requests) == fixture.TickerSubscribe(["BTC/USD"])

  browser_subscribe(second, [#("second", bitcoin_id)])
  let second_subscriber = unwrap(process.receive(subscribers, 1000))
  let _ = unwrap(process.receive(second_replies, 1000))

  assert_no_ticker_request(requests, 100)

  browser_close(first)
  await_dead(first_subscriber)

  assert_no_ticker_request(requests, 150)
  assert process.is_alive(second_subscriber)

  browser_close(second)
  await_dead(second_subscriber)

  assert await_ticker_request(requests)
    == fixture.TickerUnsubscribe(["BTC/USD"])
  assert process.is_alive(kraken.pid)
}

pub fn abrupt_browser_tcp_disconnect_cancels_all_its_subscriptions_test() {
  use kraken, requests <- fixture.with_kraken
  use url, subscribers <- with_application(kraken.data)
  use browser, replies <- with_browser(url)

  browser_subscribe(browser, [
    #("bitcoin", bitcoin_id),
    #("ethereum", ethereum_id),
  ])
  let first_subscriber = unwrap(process.receive(subscribers, 1000))
  let second_subscriber = unwrap(process.receive(subscribers, 1000))

  let _ = unwrap(process.receive(replies, 1000))
  let _ = unwrap(process.receive(replies, 1000))

  let subscribed = [
    await_ticker_request(requests),
    await_ticker_request(requests),
  ]
  assert list.contains(subscribed, fixture.TickerSubscribe(["BTC/USD"]))
  assert list.contains(subscribed, fixture.TickerSubscribe(["ETH/USD"]))

  // No WebSocket close frame: killing the client closes the underlying TCP socket.
  stop_process(browser.pid)
  await_dead(first_subscriber)
  await_dead(second_subscriber)

  let cancelled = [
    await_ticker_request(requests),
    await_ticker_request(requests),
  ]
  assert list.contains(cancelled, fixture.TickerUnsubscribe(["BTC/USD"]))
  assert list.contains(cancelled, fixture.TickerUnsubscribe(["ETH/USD"]))
  assert process.is_alive(kraken.pid)
}

pub fn malformed_request_returns_json_and_keeps_socket_usable_test() {
  use url, _ <- with_failing_provider
  use browser, replies <- with_browser(url)

  Send("not JSON")
  |> stratus.to_user_message
  |> process.send(browser.data, _)
  assert receive_response(replies) == ProtocolError

  browser_subscribe(browser, [#("bitcoin", bitcoin_id)])
  assert receive_response(replies)
    == SubscriptionFailed(
      subscription_id.from_string_unsafe("bitcoin"),
      RateRequest(bitcoin_id, usd_id),
      RateUnavailable,
    )
}

pub fn missing_currency_error_preserves_subscription_and_pair_test() {
  use url, _ <- with_failing_provider
  use browser, replies <- with_browser(url)

  browser_subscribe(browser, [#("missing", 999)])
  assert receive_response(replies)
    == SubscriptionFailed(
      subscription_id.from_string_unsafe("missing"),
      RateRequest(999, usd_id),
      CurrencyNotFound(999),
    )
}

pub fn provider_failure_can_be_followed_by_a_successful_update_test() {
  use url, reply_targets <- with_failing_provider
  use browser, replies <- with_browser(url)

  browser_subscribe(browser, [#("bitcoin", bitcoin_id)])
  let id = subscription_id.from_string_unsafe("bitcoin")
  assert receive_response(replies)
    == SubscriptionFailed(id, RateRequest(bitcoin_id, usd_id), RateUnavailable)

  let reply_to = unwrap(process.receive(reply_targets, 1000))
  let rate =
    RateResponse(
      bitcoin_id,
      usd_id,
      Some(positive_float.from_float_unsafe(100.0)),
      CoinMarketCap,
      123,
    )
  process.send(reply_to, #(id, Ok(rate)))
  assert receive_response(replies) == SubscriptionUpdate(id, rate)
}

fn receive_response(replies) {
  unwrap(process.receive(replies, 1000))
  |> json.parse(websocket_response.decoder())
  |> unwrap
}

fn with_failing_provider(run) {
  let reply_targets = process.new_subject()
  let factory = fn(id, reply_to) {
    process.send(reply_targets, reply_to)
    let currencies = [
      Crypto(bitcoin_id, "Bitcoin", "BTC", Some(1)),
      Fiat(usd_id, "US Dollar", "USD", "$"),
    ]
    let config =
      subscriber.Config(
        base: RateServiceConfig(
          get_currency: fn(id) {
            list.find(currencies, fn(currency) { currency.id == id })
          },
          kraken_interface: KrakenInterface(
            get_kraken_symbol: fn(_) { Error(Nil) },
            subscribe: fn(_) { panic },
            unsubscribe: fn(_) { panic },
            check_for_price: fn(_) { panic },
          ),
          request_cmc_conversion: fn(_) {
            Error(HttpError(httpc.InvalidUtf8Response))
          },
          get_current_time_ms: fn() { 123 },
        ),
        subscription_manager: unwrap(subscription_manager.new(1000)),
        logger: logger.new(),
      )

    subscriber.new_with_scheduler(id, reply_to, config, fn(_, _) { Nil })
    |> unwrap
  }

  use url <- with_application_factory(factory)
  run(url, reply_targets)
}

fn with_application(kraken: Subject(session.Message), run) {
  let subscribers = process.new_subject()
  let assert Ok(store) = price_store.get_store()
  let kraken_interface = create_kraken_interface(kraken, subscribers, store)
  let factory = fn(id, reply_to) {
    create_rate_subscriber(id, reply_to, kraken_interface)
  }

  use url <- with_application_factory(factory)
  run(url, subscribers)
}

fn with_application_factory(factory, run) {
  let ready = process.new_subject()
  let handler = fn(req) {
    mist.websocket(
      req,
      on_init: websocket.on_init(_, logger.new()),
      handler: fn(state, message, conn) {
        websocket.handler(state, message, conn, factory)
      },
      on_close: websocket.on_close,
    )
  }

  let server =
    handler
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
    |> mist.start
    |> unwrap
  use <- exception.defer(fn() { stop_process(server.pid) })

  let port = unwrap(process.receive(ready, 1000))
  let url = "http://127.0.0.1:" <> int.to_string(port) <> "/ws"

  run(url)
}

fn create_kraken_interface(kraken, subscribers, store) {
  KrakenInterface(
    get_kraken_symbol: kraken_symbol.new(_, pairs.exists),
    subscribe: fn(symbol) {
      process.send(subscribers, process.self())
      process.send(kraken, session.Subscribe(kraken_symbol.to_string(symbol)))
    },
    unsubscribe: fn(symbol) {
      process.send(kraken, session.Unsubscribe(kraken_symbol.to_string(symbol)))
    },
    check_for_price: fn(symbol) {
      retry.attempt(
        fn() { price_store.get_price(store, kraken_symbol.to_string(symbol)) },
        5,
        50,
      )
    },
  )
}

fn create_rate_subscriber(id, reply_to, kraken_interface) {
  let currencies = [
    Crypto(bitcoin_id, "Bitcoin", "BTC", Some(1)),
    Crypto(ethereum_id, "Ethereum", "ETH", Some(2)),
    Fiat(usd_id, "United States Dollar", "USD", "$"),
  ]
  let manager = unwrap(subscription_manager.new(1000))
  let config =
    subscriber.Config(
      base: RateServiceConfig(
        get_currency: fn(id) {
          list.find(currencies, fn(currency) { currency.id == id })
        },
        kraken_interface:,
        request_cmc_conversion: fn(_) {
          panic as "Kraken fixture must supply the price"
        },
        get_current_time_ms: time.system_time_ms,
      ),
      subscription_manager: manager,
      logger: logger.new(),
    )

  subscriber.new(id, reply_to, config)
  |> unwrap
}

fn with_browser(url, run) {
  let replies = process.new_subject()

  let browser =
    request.to(url)
    |> unwrap
    |> stratus.new(Nil)
    |> stratus.on_message(fn(state, message, conn) {
      handle_browser_message(state, message, conn, replies)
    })
    |> stratus.start
    |> unwrap
  use <- exception.defer(fn() { stop_process(browser.pid) })

  run(browser, replies)
}

fn handle_browser_message(state, message, conn, replies) {
  case message {
    stratus.Text(text) -> {
      process.send(replies, text)
      stratus.continue(state)
    }

    stratus.User(Send(text)) -> {
      let _ = unwrap(stratus.send_text_message(conn, text))
      stratus.continue(state)
    }

    stratus.User(Close) -> {
      let _ = unwrap(stratus.close(conn, stratus.Normal(<<>>)))
      stratus.stop()
    }

    stratus.Binary(_) -> stratus.continue(state)
  }
}

fn browser_subscribe(
  browser: actor.Started(Subject(stratus.InternalMessage(BrowserMessage))),
  subscriptions,
) {
  let message =
    subscriptions
    |> list.map(fn(item) {
      let #(id, currency_id) = item
      SubscriptionRequest(
        subscription_id.from_string_unsafe(id),
        RateRequest(currency_id, usd_id),
      )
    })
    |> websocket_request.Subscribe
    |> websocket_request.encode
    |> json.to_string

  Send(message)
  |> stratus.to_user_message
  |> process.send(browser.data, _)
}

fn browser_close(
  browser: actor.Started(Subject(stratus.InternalMessage(BrowserMessage))),
) {
  Close
  |> stratus.to_user_message
  |> process.send(browser.data, _)
}

fn await_ticker_request(requests) {
  let #(_, message) = unwrap(process.receive(requests, 1000))

  case message {
    fixture.TickerSubscribe(_) | fixture.TickerUnsubscribe(_) -> message
    _ -> await_ticker_request(requests)
  }
}

fn assert_no_ticker_request(requests, duration_ms) {
  let deadline = time.monotonic_time_ms() + duration_ms
  assert_no_ticker_until(requests, deadline)
}

fn assert_no_ticker_until(requests, deadline) {
  let remaining = int.max(0, deadline - time.monotonic_time_ms())

  case process.receive(requests, remaining) {
    Ok(#(_, fixture.TickerSubscribe(_)))
    | Ok(#(_, fixture.TickerUnsubscribe(_))) ->
      panic as "Unexpected upstream subscription change"

    Ok(_) -> assert_no_ticker_until(requests, deadline)
    Error(_) -> Nil
  }
}

fn await_dead(pid: Pid) {
  let monitor = process.monitor(pid)

  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
    |> unwrap

  Nil
}

fn stop_process(pid: Pid) {
  process.unlink(pid)
  process.kill(pid)
  await_dead(pid)
}

fn unwrap(value) {
  let assert Ok(value) = value
  value
}
