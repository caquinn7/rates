import exception
import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor.{type Started}
import mist
import server/integrations/coin_market_cap/client.{
  type CmcRequestError, type CmcResponse, CmcResponse, CmcStatus, HttpError,
}
import server/integrations/coin_market_cap/cmc_conversion.{
  type CmcConversion, CmcConversion, QuoteItem,
}
import server/integrations/kraken/client_recovery_test as fixture
import server/integrations/kraken/internal/session as kraken_session
import server/integrations/kraken/pairs
import server/integrations/kraken/price_store.{type PriceStore}
import server/rates/internal/cmc_rate_handler.{type RequestCmcConversion}
import server/rates/internal/kraken_interface.{
  type KrakenInterface, KrakenInterface,
}
import server/rates/internal/kraken_symbol
import server/rates/internal/subscription_manager
import server/rates/subscriber.{type RateSubscriber, type SubscriptionResult}
import server/rates/subscriber_factory.{type SubscriberFactory}
import server/utils/logger
import server/utils/retry
import server/utils/time
import server/web/routes/websocket
import shared/currency.{Crypto, Fiat}
import shared/numbers/positive_float
import shared/rates/rate_request.{RateRequest}
import shared/rates/rate_response.{CoinMarketCap, RateResponse}
import shared/subscriptions/subscription_id.{type SubscriptionId}
import shared/subscriptions/subscription_request.{SubscriptionRequest}
import shared/websocket_request
import shared/websocket_response.{
  type WebsocketResponse, CurrencyNotFound, ProtocolError, RateUnavailable,
  SubscriptionFailed, SubscriptionUpdate,
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

pub fn provider_response_timeout_can_be_followed_by_a_successful_update_test() {
  use url, reply_targets <- with_failing_provider
  use browser, replies <- with_browser(url)

  browser_subscribe(browser, [#("bitcoin", bitcoin_id)])
  let id = subscription_id.from_string_unsafe("bitcoin")
  assert receive_response(replies)
    == SubscriptionFailed(id, RateRequest(bitcoin_id, usd_id), RateUnavailable)

  let #(target, reply_to) = unwrap(process.receive(reply_targets, 1000))
  let rate =
    RateResponse(
      bitcoin_id,
      usd_id,
      Some(positive_float.from_float_unsafe(100.0)),
      CoinMarketCap,
      123,
    )
  process.send(reply_to, #(target, Ok(rate)))
  assert receive_response(replies) == SubscriptionUpdate(id, rate)
}

pub fn unsubscribe_drops_in_flight_rate_result_test() {
  use url, lookup_started <- with_blocked_cmc_provider
  use browser, replies <- with_browser(url)

  browser_subscribe(browser, [#("bitcoin", bitcoin_id)])
  let #(subscriber_pid, release_lookup) =
    unwrap(process.receive(lookup_started, 1000))

  browser_unsubscribe(browser, "bitcoin")

  // The response to the next frame confirms Unsubscribe has been processed.
  Send("not JSON")
  |> stratus.to_user_message
  |> process.send(browser.data, _)
  assert receive_response(replies) == ProtocolError

  process.send(release_lookup, Error(HttpError(httpc.ResponseTimeout)))
  await_dead(subscriber_pid)
  assert process.receive(replies, 200) == Error(Nil)
}

pub fn resubscribing_with_same_id_drops_in_flight_result_from_old_subscriber_test() {
  use url, lookup_started <- with_blocked_cmc_provider
  use browser, replies <- with_browser(url)

  browser_subscribe(browser, [#("bitcoin", bitcoin_id)])
  let #(old_pid, release_old) = unwrap(process.receive(lookup_started, 1000))

  browser_unsubscribe(browser, "bitcoin")
  browser_subscribe(browser, [#("bitcoin", bitcoin_id)])
  let #(new_pid, release_new) = unwrap(process.receive(lookup_started, 1000))
  assert new_pid != old_pid

  process.send(release_old, Error(HttpError(httpc.ResponseTimeout)))
  await_dead(old_pid)

  let price = Some(positive_float.from_float_unsafe(100.0))
  let conversion =
    CmcConversion(
      bitcoin_id,
      "BTC",
      "Bitcoin",
      positive_float.from_float_unsafe(1.0),
      dict.from_list([#(int.to_string(usd_id), QuoteItem(price, 123))]),
    )
  process.send(
    release_new,
    Ok(CmcResponse(CmcStatus(0, None), Some(conversion))),
  )
  assert receive_response(replies)
    == SubscriptionUpdate(
      subscription_id.from_string_unsafe("bitcoin"),
      RateResponse(bitcoin_id, usd_id, price, CoinMarketCap, 123),
    )
  assert process.receive(replies, 200) == Error(Nil)
}

fn receive_response(replies: Subject(String)) -> WebsocketResponse {
  replies
  |> process.receive(1000)
  |> unwrap
  |> json.parse(websocket_response.decoder())
  |> unwrap
}

fn with_failing_provider(
  run: fn(String, Subject(#(RateSubscriber, Subject(SubscriptionResult)))) -> a,
) -> a {
  with_cmc_provider(fn(_) { Error(HttpError(httpc.ResponseTimeout)) }, run)
}

fn with_cmc_provider(
  request_cmc_conversion: RequestCmcConversion,
  run: fn(String, Subject(#(RateSubscriber, Subject(SubscriptionResult)))) -> a,
) -> a {
  let reply_targets = process.new_subject()
  let factory = fn(id, reply_to) {
    let currencies = [
      Crypto(bitcoin_id, "Bitcoin", "BTC", Some(1)),
      Fiat(usd_id, "US Dollar", "USD", "$"),
    ]
    let config =
      subscriber.Config(
        get_currency: fn(id) {
          list.find(currencies, fn(currency) { currency.id == id })
        },
        kraken_interface: KrakenInterface(
          get_kraken_symbol: fn(_) { Error(Nil) },
          subscribe: fn(_) { panic },
          unsubscribe: fn(_) { panic },
          check_for_price: fn(_) { panic },
        ),
        request_cmc_conversion:,
        subscription_manager: unwrap(subscription_manager.new(1000)),
        logger: logger.new(),
      )

    let target =
      subscriber.new_with_scheduler(id, reply_to, config, fn(_, _) { Nil })
      |> unwrap
    process.send(reply_targets, #(target, reply_to))
    target
  }

  use url <- with_application_factory(factory)
  run(url, reply_targets)
}

fn with_blocked_cmc_provider(
  run: fn(
    String,
    Subject(
      #(Pid, Subject(Result(CmcResponse(CmcConversion), CmcRequestError))),
    ),
  ) -> a,
) -> a {
  let lookup_started = process.new_subject()
  let request_cmc_conversion = fn(_) {
    let release_lookup = process.new_subject()
    process.send(lookup_started, #(process.self(), release_lookup))
    unwrap(process.receive(release_lookup, 2000))
  }

  use url, _ <- with_cmc_provider(request_cmc_conversion)
  run(url, lookup_started)
}

fn with_application(
  kraken: Subject(kraken_session.Message),
  run: fn(String, Subject(Pid)) -> a,
) -> a {
  let subscribers = process.new_subject()
  let assert Ok(store) = price_store.get_store()
  let kraken_interface = create_kraken_interface(kraken, subscribers, store)
  let factory = fn(id, reply_to) {
    create_rate_subscriber(id, reply_to, kraken_interface)
  }

  use url <- with_application_factory(factory)
  run(url, subscribers)
}

fn with_application_factory(
  factory: SubscriberFactory,
  run: fn(String) -> a,
) -> a {
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

fn create_kraken_interface(
  kraken: Subject(kraken_session.Message),
  subscribers: Subject(Pid),
  store: PriceStore,
) -> KrakenInterface {
  KrakenInterface(
    get_kraken_symbol: kraken_symbol.new(_, pairs.exists),
    subscribe: fn(symbol) {
      process.send(subscribers, process.self())
      process.send(
        kraken,
        kraken_session.Subscribe(kraken_symbol.to_string(symbol)),
      )
    },
    unsubscribe: fn(symbol) {
      process.send(
        kraken,
        kraken_session.Unsubscribe(kraken_symbol.to_string(symbol)),
      )
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

fn create_rate_subscriber(
  id: SubscriptionId,
  reply_to: Subject(SubscriptionResult),
  kraken_interface: KrakenInterface,
) -> RateSubscriber {
  let currencies = [
    Crypto(bitcoin_id, "Bitcoin", "BTC", Some(1)),
    Crypto(ethereum_id, "Ethereum", "ETH", Some(2)),
    Fiat(usd_id, "United States Dollar", "USD", "$"),
  ]
  let manager = unwrap(subscription_manager.new(1000))
  let config =
    subscriber.Config(
      get_currency: fn(id) {
        list.find(currencies, fn(currency) { currency.id == id })
      },
      kraken_interface:,
      request_cmc_conversion: fn(_) {
        panic as "Kraken fixture must supply the price"
      },
      subscription_manager: manager,
      logger: logger.new(),
    )

  subscriber.new(id, reply_to, config)
  |> unwrap
}

fn with_browser(
  url: String,
  run: fn(
    Started(Subject(stratus.InternalMessage(BrowserMessage))),
    Subject(String),
  ) -> a,
) -> a {
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

fn handle_browser_message(
  state: a,
  message: stratus.Message(BrowserMessage),
  conn: stratus.Connection,
  replies: Subject(String),
) -> stratus.Next(a, b) {
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
  browser: Started(Subject(stratus.InternalMessage(BrowserMessage))),
  subscriptions: List(#(String, Int)),
) -> Nil {
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
  browser: Started(Subject(stratus.InternalMessage(BrowserMessage))),
) -> Nil {
  Close
  |> stratus.to_user_message
  |> process.send(browser.data, _)
}

fn browser_unsubscribe(
  browser: Started(Subject(stratus.InternalMessage(BrowserMessage))),
  id: String,
) -> Nil {
  id
  |> subscription_id.from_string_unsafe
  |> websocket_request.Unsubscribe
  |> websocket_request.encode
  |> json.to_string
  |> Send
  |> stratus.to_user_message
  |> process.send(browser.data, _)
}

fn await_ticker_request(
  requests: Subject(#(a, fixture.Request)),
) -> fixture.Request {
  let #(_, message) = unwrap(process.receive(requests, 1000))

  case message {
    fixture.TickerSubscribe(_) | fixture.TickerUnsubscribe(_) -> message
    _ -> await_ticker_request(requests)
  }
}

fn assert_no_ticker_request(
  requests: Subject(#(a, fixture.Request)),
  duration_ms: Int,
) -> Nil {
  let deadline = time.monotonic_time_ms() + duration_ms
  assert_no_ticker_until(requests, deadline)
}

fn assert_no_ticker_until(
  requests: Subject(#(a, fixture.Request)),
  deadline: Int,
) -> Nil {
  let remaining = int.max(0, deadline - time.monotonic_time_ms())

  case process.receive(requests, remaining) {
    Ok(#(_, fixture.TickerSubscribe(_)))
    | Ok(#(_, fixture.TickerUnsubscribe(_))) ->
      panic as "Unexpected upstream subscription change"

    Ok(_) -> assert_no_ticker_until(requests, deadline)
    Error(_) -> Nil
  }
}

fn await_dead(pid: Pid) -> Nil {
  let monitor = process.monitor(pid)

  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
    |> unwrap

  Nil
}

fn stop_process(pid: Pid) -> Nil {
  process.unlink(pid)
  process.kill(pid)
  await_dead(pid)
}

fn unwrap(value: Result(a, b)) -> a {
  let assert Ok(value) = value
  value
}
