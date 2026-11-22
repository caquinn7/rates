import exception
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/response as http_response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import glight
import mist
import server/integrations/kraken/client as kraken_client
import server/integrations/kraken/internal/connection
import server/integrations/kraken/internal/request as kraken_request
import server/integrations/kraken/internal/response.{
  TickerResponse, TickerSubscribeConfirmation,
}
import server/integrations/kraken/internal/session.{
  ConnectionEvent, DiscoveryDeadlineReached, GenerationEvent,
  ReconnectDelayElapsed, StabilityIntervalElapsed, Subscribe, Unsubscribe,
}
import server/integrations/kraken/pairs
import server/integrations/kraken/price_store
import server/utils/logger.{type LogEntry, LogEntry}
import server/utils/retry
import server/utils/time
import shared/numbers/positive_float

/// Scripts the fixture's response to a WebSocket connection attempt.
type Plan {
  /// Accepts with automatic ticker replies. Sends an instrument snapshot on
  /// subscribe when `snapshot` is `True`.
  Accept(snapshot: Bool)

  /// Accepts and sends an instrument snapshot. The test sends ticker
  /// confirmations and quotes explicitly.
  ManualTickers

  /// Rejects the WebSocket upgrade with HTTP 503.
  Reject

  /// Waits the given number of milliseconds before accepting with an
  /// instrument snapshot and automatic ticker replies.
  DelayedAccept(Int)
}

/// Commands a test can send to an open fixture socket.
type Control {
  /// Sends a WebSocket text frame containing the supplied payload.
  Send(String)

  /// Closes the fixture socket to simulate a normal disconnect.
  Close
}

pub type Request {
  InstrumentSubscribe
  InstrumentUnsubscribe
  TickerSubscribe(List(String), Int)
  TickerUnsubscribe(List(String))
  UnexpectedMethod(String)
}

/// Reports a WebSocket connection accepted by the fixture.
type Opened {
  Opened(
    /// Zero-based attempt number. Rejected attempts also advance the count.
    attempt: Int,
    /// Subject for sending commands to the open socket.
    control: Subject(Control),
    /// Fixture socket process used for liveness checks and abrupt disconnects.
    pid: Pid,
  )
}

/// Reports connection attempts and client requests from the scripted server.
type Fixture {
  Fixture(
    /// Reports each accepted WebSocket when its socket process starts.
    opened: Subject(Opened),
    /// Reports each decoded client request with its connection attempt number.
    requests: Subject(#(Int, Request)),
    /// Reports every attempt number and its monotonic timestamp in milliseconds,
    /// including attempts the server rejects.
    attempts: Subject(#(Int, Int)),
  )
}

/// Requests a plan for the next connection attempt and advances the sequence.
type NextAttempt {
  NextAttempt(
    /// Receives the zero-based attempt number and its plan.
    Subject(#(Int, Plan)),
  )
}

fn config() {
  session.Config(
    ..session.default_config(),
    connect_timeout_ms: 500,
    discovery_timeout_ms: 500,
    stable_connection_ms: 10_000,
    retry_base_ms: 30,
    retry_max_ms: 120,
    jitter_ms: fn() { 0 },
  )
}

fn inactivity_test_config() {
  session.Config(..config(), inactivity_timeout_ms: 500)
}

const heartbeat = "{\"channel\":\"heartbeat\"}"

/// Run application WebSocket tests against the same scripted Kraken endpoint.
pub fn with_kraken(run) {
  use fixture, url <- with_server([])
  use client, _, _ <- with_client(fixture, url, config())
  run(client, fixture.requests)
}

pub fn concurrent_sessions_keep_their_prices_and_pairs_independent_test() {
  let symbol = "BTC/USD"
  use first_fixture, first_url <- with_server([])
  use first, first_socket, first_ready <- with_client(
    first_fixture,
    first_url,
    config(),
  )
  process.send(first.data.subject, Subscribe(symbol))
  let first_prices = first.data.price_store
  let first_pairs = first.data.pair_store
  let first_quote = await_price(first_prices, 100.0, 100)
  assert pairs.exists(first_pairs, symbol)

  // Hold the second snapshot so readiness can be checked while the first
  // session already has pairs and prices.
  use second_fixture, second_url <- with_server([Accept(False)])
  let second_logs = process.new_subject()
  let second_owner = process.new_subject()
  let second_logger =
    logger.new_with_sink(glight.Info, process.send(second_logs, _))
  let create_store = fn() {
    let store = unwrap(price_store.new())
    process.send(second_owner, process.self())
    store
  }
  let second =
    unwrap(kraken_client.new_with_url(second_logger, create_store, second_url))
  let second_pid = unwrap(process.receive(second_owner, 1000))
  use <- exception.defer(fn() { stop_process(second_pid) })

  let second_socket = await_open(second_fixture, 0)
  assert next_request(second_fixture, 0) == InstrumentSubscribe
  assert !kraken_client.has_supported_pairs(second)
  assert !kraken_client.supports_symbol(second, symbol)
  assert kraken_client.get_price(second, symbol) == Error(Nil)

  process.send(second_socket.control, Send(instrument_json("snapshot", [])))
  let _ = await_ready(second_logs, second_pid, 0)
  assert !kraken_client.has_supported_pairs(second)

  kraken_client.subscribe(second, symbol)
  process.send(
    second_socket.control,
    Send(
      instrument_json("update", [#(symbol, "online"), #("XRP/USD", "online")]),
    ),
  )
  let _ = await_request(second_fixture, 0, is_ticker_subscribe(symbol, _))
  assert kraken_client.has_supported_pairs(second)
  assert kraken_client.supports_symbol(second, symbol)
  assert !pairs.exists(first_pairs, "XRP/USD")

  process.send(second_socket.control, Send(ticker_json(symbol, 200)))
  let second_price = positive_float.from_float_unsafe(200.0)
  let assert Ok(second_quote) =
    retry.attempt(
      fn() {
        case kraken_client.get_price(second, symbol) {
          Ok(entry) if entry.price == second_price -> Ok(entry)
          _ -> Error(Nil)
        }
      },
      100,
      5,
    )
  assert price_store.get_price(first_prices, symbol) == Ok(first_quote)

  // Evict the shared symbol from the first session only, then restore its
  // subscription on a new socket using the same pair and price handles.
  process.send(
    first_socket.control,
    Send(instrument_json("update", [#(symbol, "delisted")])),
  )
  await_pair(first_pairs, symbol, False, 100)
  assert price_store.get_price(first_prices, symbol) == Error(Nil)
  assert kraken_client.supports_symbol(second, symbol)
  assert kraken_client.get_price(second, symbol) == Ok(second_quote)

  process.send(first_socket.control, Close)
  let reopened = await_open(first_fixture, 1)
  let _ = await_ready(first_ready, first.pid, 1)
  let _ = await_request(first_fixture, 1, is_ticker_subscribe(symbol, _))
  assert pairs.exists(first_pairs, symbol)
  process.send(reopened.control, Send(ticker_json(symbol, 101)))
  let _ = await_price(first_prices, 101.0, 100)
  assert kraken_client.get_price(second, symbol) == Ok(second_quote)

  stop_process(first.pid)
  assert kraken_client.has_supported_pairs(second)
  assert kraken_client.supports_symbol(second, symbol)
  assert kraken_client.supports_symbol(second, "XRP/USD")
  assert kraken_client.get_price(second, symbol) == Ok(second_quote)
}

pub fn heartbeats_keep_the_socket_open_until_inbound_traffic_stops_test() {
  let logs = process.new_subject()
  let client_logger = logger.new_with_sink(glight.Info, process.send(logs, _))
  let cfg = inactivity_test_config()
  use fixture, url <- with_server([])
  use client <- start_client_with_logger(url, cfg, client_logger)

  let first = await_open(fixture, 0)
  let _ = await_ready(logs, client.pid, 0)
  assert next_request(fixture, 0) == InstrumentSubscribe

  assert_periodic_text_keeps_socket_open(fixture, first, heartbeat)

  let reason = await_retry_logs(logs, string.inspect(client.pid), 0, 30)
  assert string.contains(reason, "Kraken inbound inactivity timeout")
  let _ = await_open(fixture, 1)
  let _ = await_ready(logs, client.pid, 1)
}

pub fn ticker_updates_keep_the_socket_open_without_heartbeats_test() {
  use fixture, url <- with_server([])
  use client, opened, _ <- with_client(fixture, url, inactivity_test_config())
  assert next_request(fixture, 0) == InstrumentSubscribe

  process.send(client.data.subject, Subscribe("BTC/USD"))
  let assert TickerSubscribe(["BTC/USD"], _) = next_request(fixture, 0)
  let store = client.data.price_store
  let _ = await_price(store, 100.0, 100)

  assert_periodic_text_keeps_socket_open(
    fixture,
    opened,
    ticker_json("BTC/USD", 101),
  )
  let _ = await_price(store, 101.0, 100)
}

pub fn malformed_text_counts_as_activity_and_logs_a_warning_test() {
  let logs = process.new_subject()
  let client_logger = logger.new_with_sink(glight.Info, process.send(logs, _))
  use fixture, url <- with_server([])
  use client <- start_client_with_logger(
    url,
    inactivity_test_config(),
    client_logger,
  )

  let opened = await_open(fixture, 0)
  let _ = await_ready(logs, client.pid, 0)
  assert next_request(fixture, 0) == InstrumentSubscribe

  let malformed = "{not-json"
  assert_periodic_text_keeps_socket_open(fixture, opened, malformed)

  let LogEntry(level, message, fields) = unwrap(process.receive(logs, 0))
  assert level == glight.Warning
  assert message == "Unable to decode Kraken response"
  assert dict.get(fields, "response") == Ok(malformed)
}

pub fn stale_deadline_cannot_end_new_instrument_discovery_test() {
  use fixture, url <- with_server([Accept(True), Accept(False)])
  use client, first, ready <- with_client(fixture, url, config())

  process.send(first.control, Close)
  let recovered = await_open(fixture, 1)
  let _ = await_request(fixture, 1, fn(req) { req == InstrumentSubscribe })

  process.send(
    client.data.subject,
    GenerationEvent(0, DiscoveryDeadlineReached),
  )
  let assert Some(snapshot) =
    unwrap(json.parse(instrument_snapshot(), response.decoder()))

  // Send both events from this process so the stale deadline is handled first.
  process.send(
    client.data.subject,
    GenerationEvent(1, ConnectionEvent(connection.Received(snapshot))),
  )

  let _ = await_ready(ready, client.pid, 1)
  assert process.is_alive(client.pid)
  assert process.is_alive(recovered.pid)
  assert process.receive(fixture.opened, 0) == Error(Nil)
}

pub fn repeated_reconnects_leave_only_the_current_worker_and_socket_test() {
  use fixture, url <- with_server([])
  use client, first, ready <- with_client(fixture, url, config())

  let _ =
    list.fold([1, 2, 3], first, fn(previous, attempt) {
      let assert [worker] = monitored_processes(client.pid)
      let assert [socket] = linked_processes(worker)

      process.send(previous.control, Close)
      let opened = await_open(fixture, attempt)
      let _ = await_ready(ready, client.pid, attempt)

      await_dead(worker, 100)
      await_dead(socket, 100)
      let assert [_] = monitored_processes(client.pid)

      opened
    })

  assert process.is_alive(client.pid)
}

pub fn unexpected_worker_exit_reconnects_and_preserves_subscription_state_test() {
  use fixture, url <- with_server([])
  use client, _, _ <- with_client(fixture, url, config())

  process.send(client.data.subject, Subscribe("BTC/USD"))
  let _ = await_request(fixture, 0, is_ticker_subscribe("BTC/USD", _))

  let store = client.data.price_store
  let cached = await_price(store, 100.0, 100)
  assert cached.timestamp == 1_794_146_160_550
  assert price_store.get_price(store, "BTC/USD") == Ok(cached)

  let assert [worker] = monitored_processes(client.pid)
  let assert [socket] = linked_processes(worker)

  // An unexpected worker exit provides no connection.Failed notification.
  process.kill(worker)
  let recovered = await_open(fixture, 1)
  let _ = await_request(fixture, 1, is_ticker_subscribe("BTC/USD", _))

  await_dead(worker, 100)
  await_dead(socket, 100)
  assert process.is_alive(client.pid)
  assert price_store.get_price(store, "BTC/USD") == Ok(cached)

  process.send(
    recovered.control,
    Send(ticker_json_with_timestamp(
      "BTC/USD",
      101,
      "2026-11-08T13:57:00.999999Z",
    )),
  )
  let fresh = await_price(store, 101.0, 100)
  assert fresh.timestamp == 1_794_146_220_999

  process.send(client.data.subject, Unsubscribe("BTC/USD"))
  let _ =
    await_request(fixture, 1, fn(req) { req == TickerUnsubscribe(["BTC/USD"]) })
}

pub fn invalid_ticker_timestamps_preserve_cached_prices_test() {
  use fixture, url <- with_server([])
  use client, opened, _ <- with_client(fixture, url, config())

  process.send(client.data.subject, Subscribe("BTC/USD"))
  let _ = await_request(fixture, 0, is_ticker_subscribe("BTC/USD", _))
  process.send(client.data.subject, Subscribe("ETH/USD"))
  let _ = await_request(fixture, 0, is_ticker_subscribe("ETH/USD", _))

  let store = client.data.price_store
  let cached = await_price(store, 100.0, 100)
  let _ = await_symbol_price(store, "ETH/USD", 100.0, 100)

  [
    "{\"channel\":\"ticker\",\"type\":\"update\",\"data\":[{\"symbol\":\"BTC/USD\",\"last\":999}]}",
    "{\"channel\":\"ticker\",\"type\":\"update\",\"data\":[{\"symbol\":\"BTC/USD\",\"last\":999,\"timestamp\":null}]}",
    ticker_json_with_timestamp("BTC/USD", 999, "invalid"),
    ticker_json_with_timestamp("BTC/USD", 999, "2026-02-30T00:00:00Z"),
  ]
  |> list.each(fn(payload) { process.send(opened.control, Send(payload)) })

  // A valid update on the same socket proves the preceding frames were handled.
  process.send(opened.control, Send(ticker_json("ETH/USD", 101)))
  let _ = await_symbol_price(store, "ETH/USD", 101.0, 100)
  assert price_store.get_price(store, "BTC/USD") == Ok(cached)
  assert process.is_alive(client.pid)
}

pub fn instrument_updates_keep_existing_pairs_and_add_new_listings_test() {
  use fixture, url <- with_server([])
  use client, opened, _ <- with_client(fixture, url, config())

  process.send(client.data.subject, Subscribe("BTC/USD"))
  let _ =
    await_request(fixture, 0, fn(request) {
      assert request != InstrumentUnsubscribe
      is_ticker_subscribe("BTC/USD", request)
    })
  let store = client.data.price_store
  let cached = await_price(store, 100.0, 100)
  assert !pairs.exists(client.data.pair_store, "XRP/USD")

  process.send(opened.control, Send(instrument_json("update", [])))
  process.send(
    opened.control,
    Send(
      instrument_json("update", [
        #("BTC/USD", "maintenance"),
        #("XRP/USD", "online"),
      ]),
    ),
  )
  await_pair(client.data.pair_store, "XRP/USD", True, 100)

  assert pairs.exists(client.data.pair_store, "BTC/USD")
  assert pairs.exists(client.data.pair_store, "ETH/USD")
  assert price_store.get_price(store, "BTC/USD") == Ok(cached)

  process.send(client.data.subject, Subscribe("XRP/USD"))
  let _ =
    await_request(fixture, 0, fn(request) {
      assert request != InstrumentUnsubscribe
      assert request != TickerUnsubscribe(["BTC/USD"])
      is_ticker_subscribe("XRP/USD", request)
    })
  let _ = await_symbol_price(store, "XRP/USD", 100.0, 100)
  assert process.receive(fixture.opened, 0) == Error(Nil)
}

pub fn first_interest_in_an_unsupported_pair_waits_for_listing_test() {
  use fixture, url <- with_server([])
  use client, opened, _ <- with_client(fixture, url, config())
  assert next_request(fixture, 0) == InstrumentSubscribe
  assert !pairs.exists(client.data.pair_store, "XRP/USD")

  process.send(client.data.subject, Subscribe("XRP/USD"))
  process.send(client.data.subject, Subscribe("ETH/USD"))
  let assert TickerSubscribe(["ETH/USD"], _) = next_request(fixture, 0)

  process.send(
    opened.control,
    Send(instrument_json("update", [#("XRP/USD", "online")])),
  )
  let assert TickerSubscribe(["XRP/USD"], _) = next_request(fixture, 0)

  let store = client.data.price_store
  let _ = await_symbol_price(store, "XRP/USD", 100.0, 100)
  assert pairs.exists(client.data.pair_store, "XRP/USD")

  process.send(client.data.subject, Unsubscribe("XRP/USD"))
  assert next_request(fixture, 0) == TickerUnsubscribe(["XRP/USD"])
}

pub fn relisting_restores_shared_interest_and_requires_fresh_confirmation_test() {
  use fixture, url <- with_server([ManualTickers])
  use client, opened, _ <- with_client(fixture, url, config())

  process.send(client.data.subject, Subscribe("BTC/USD"))
  process.send(client.data.subject, Subscribe("BTC/USD"))
  let assert TickerSubscribe(_, old_id) =
    await_request(fixture, 0, is_ticker_subscribe("BTC/USD", _))
  process.send(
    opened.control,
    Send(ticker_confirmation_json("BTC/USD", old_id)),
  )
  process.send(opened.control, Send(ticker_json("BTC/USD", 100)))

  let store = client.data.price_store
  let _ = await_price(store, 100.0, 100)
  process.send(
    opened.control,
    Send(instrument_json("update", [#("BTC/USD", "delisted")])),
  )
  let _ =
    await_request(fixture, 0, fn(req) { req == TickerUnsubscribe(["BTC/USD"]) })
  await_pair(client.data.pair_store, "BTC/USD", False, 100)
  assert price_store.get_price(store, "BTC/USD") == Error(Nil)

  // A client can look up a pair just before it is removed and release it later.
  process.send(client.data.subject, Subscribe("BTC/USD"))
  process.send(client.data.subject, Unsubscribe("BTC/USD"))
  process.send(client.data.subject, Subscribe("ETH/USD"))
  let assert TickerSubscribe(_, eth_id) =
    await_request(fixture, 0, fn(request) {
      assert !is_ticker_subscribe("BTC/USD", request)
      assert request != TickerUnsubscribe(["BTC/USD"])
      is_ticker_subscribe("ETH/USD", request)
    })
  process.send(
    opened.control,
    Send(ticker_confirmation_json("ETH/USD", eth_id)),
  )

  process.send(opened.control, Send(ticker_json("BTC/USD", 999)))
  process.send(
    opened.control,
    Send(instrument_json("update", [#("BTC/USD", "online")])),
  )
  let assert TickerSubscribe(_, new_id) =
    await_request(fixture, 0, is_ticker_subscribe("BTC/USD", _))
  assert new_id != old_id
  assert pairs.exists(client.data.pair_store, "BTC/USD")
  assert price_store.get_price(store, "BTC/USD") == Error(Nil)

  // Use the ETH quote as a barrier after messages with the wrong ID or symbol.
  process.send(
    opened.control,
    Send(ticker_confirmation_json("BTC/USD", old_id)),
  )
  process.send(
    opened.control,
    Send(ticker_confirmation_json("ETH/USD", new_id)),
  )
  process.send(opened.control, Send(ticker_json("BTC/USD", 999)))
  process.send(opened.control, Send(ticker_json("ETH/USD", 101)))
  let _ = await_symbol_price(store, "ETH/USD", 101.0, 100)
  assert price_store.get_price(store, "BTC/USD") == Error(Nil)

  process.send(
    opened.control,
    Send(ticker_confirmation_json("BTC/USD", new_id)),
  )
  process.send(opened.control, Send(ticker_json("BTC/USD", 102)))
  let _ = await_price(store, 102.0, 100)

  // The first BTC release keeps its shared ticker alive, so ETH is next.
  process.send(client.data.subject, Unsubscribe("BTC/USD"))
  process.send(client.data.subject, Unsubscribe("ETH/USD"))
  assert next_request(fixture, 0) == TickerUnsubscribe(["ETH/USD"])

  process.send(client.data.subject, Unsubscribe("BTC/USD"))
  assert next_request(fixture, 0) == TickerUnsubscribe(["BTC/USD"])
  assert process.is_alive(client.pid)
}

pub fn second_snapshot_evicts_removed_pairs_on_the_same_connection_test() {
  use fixture, url <- with_server([])
  use client, opened, _ <- with_client(fixture, url, config())
  assert next_request(fixture, 0) == InstrumentSubscribe

  process.send(client.data.subject, Subscribe("BTC/USD"))
  process.send(client.data.subject, Subscribe("ETH/USD"))
  let assert TickerSubscribe(["BTC/USD"], _) = next_request(fixture, 0)
  let assert TickerSubscribe(["ETH/USD"], _) = next_request(fixture, 0)

  let store = client.data.price_store
  let _ = await_price(store, 100.0, 100)
  let eth = await_symbol_price(store, "ETH/USD", 100.0, 100)

  process.send(
    opened.control,
    Send(instrument_json("snapshot", [#("ETH/USD", "online")])),
  )
  assert next_request(fixture, 0) == TickerUnsubscribe(["BTC/USD"])
  await_pair(client.data.pair_store, "BTC/USD", False, 100)
  assert price_store.get_price(store, "BTC/USD") == Error(Nil)
  assert pairs.exists(client.data.pair_store, "ETH/USD")
  assert price_store.get_price(store, "ETH/USD") == Ok(eth)

  process.send(opened.control, Send(ticker_json("ETH/USD", 101)))
  let _ = await_symbol_price(store, "ETH/USD", 101.0, 100)

  // The next request confirms the snapshot produced one ticker unsubscribe.
  process.send(client.data.subject, Unsubscribe("ETH/USD"))
  assert next_request(fixture, 0) == TickerUnsubscribe(["ETH/USD"])
  assert process.receive(fixture.opened, 0) == Error(Nil)
}

pub fn reconnect_snapshot_evicts_removed_pairs_and_restores_listed_tickers_test() {
  use fixture, url <- with_server([Accept(True), Accept(False)])
  use client, first, ready <- with_client(fixture, url, config())

  process.send(client.data.subject, Subscribe("BTC/USD"))
  process.send(client.data.subject, Subscribe("ETH/USD"))
  let store = client.data.price_store
  let _ = await_price(store, 100.0, 100)
  let eth = await_symbol_price(store, "ETH/USD", 100.0, 100)

  process.send(first.control, Close)
  let second = await_open(fixture, 1)
  let _ = await_request(fixture, 1, fn(req) { req == InstrumentSubscribe })
  process.send(
    second.control,
    Send(instrument_json("snapshot", [#("ETH/USD", "online")])),
  )

  let fields = await_ready(ready, client.pid, 1)
  assert dict.get(fields, "restored_symbols") == Ok("1")
  let _ =
    await_request(fixture, 1, fn(request) {
      assert !is_ticker_subscribe("BTC/USD", request)
      is_ticker_subscribe("ETH/USD", request)
    })

  assert !pairs.exists(client.data.pair_store, "BTC/USD")
  assert pairs.exists(client.data.pair_store, "ETH/USD")
  assert price_store.get_price(store, "BTC/USD") == Error(Nil)
  assert price_store.get_price(store, "ETH/USD") == Ok(eth)
  process.send(second.control, Send(ticker_json("ETH/USD", 101)))
  let _ = await_symbol_price(store, "ETH/USD", 101.0, 100)
}

pub fn shutdown_during_reconnect_handshake_cleans_up_the_attempt_test() {
  use fixture, url <- with_server([Accept(True), DelayedAccept(200)])
  use client, first, _ <- with_client(fixture, url, config())

  process.send(first.control, Close)
  let _ = await_attempt(fixture, 1)

  let assert [worker] = monitored_processes(client.pid)
  let assert [socket] = linked_processes(worker)

  stop_process(client.pid)

  await_dead(worker, 150)
  await_dead(socket, 150)
}

pub fn normal_close_preserves_cache_counts_and_ignores_old_connection_events_test() {
  let logs = process.new_subject()
  let client_logger = logger.new_with_sink(glight.Info, process.send(logs, _))
  use fixture, url <- with_server([Accept(True), Accept(False)])
  use client <- start_client_with_logger(url, config(), client_logger)

  let first = await_open(fixture, 0)
  let session_pid = string.inspect(client.pid)
  let ready =
    await_session_log(
      logs,
      session_pid,
      glight.Info,
      "Kraken connection ready",
      0,
    )
  assert dict.get(ready, "restored_symbols") == Ok("0")

  process.send(client.data.subject, Subscribe("BTC/USD"))
  process.send(client.data.subject, Subscribe("BTC/USD"))
  let _ = await_request(fixture, 0, is_ticker_subscribe("BTC/USD", _))

  let store = client.data.price_store
  let old = await_price(store, 100.0, 100)
  let assert [first_worker] = monitored_processes(client.pid)
  let assert [first_socket] = linked_processes(first_worker)

  process.send(first.control, Close)
  assert await_retry_logs(logs, session_pid, 0, 30) == "Normal"
  let second = await_open(fixture, 1)

  assert process.is_alive(client.pid)
  assert !process.is_alive(first_worker)
  assert !process.is_alive(first_socket)
  assert price_store.get_price(store, "BTC/USD") == Ok(old)

  // The replacement requests a snapshot before it can become ready.
  let _ = await_request(fixture, 1, fn(req) { req == InstrumentSubscribe })
  assert receive_session_log(logs, session_pid, time.monotonic_time_ms())
    == Error(Nil)

  process.send(second.control, Send(instrument_snapshot()))
  let recovered =
    await_session_log(
      logs,
      session_pid,
      glight.Info,
      "Kraken connection ready",
      1,
    )
  assert dict.get(recovered, "restored_symbols") == Ok("1")
  let assert Ok(downtime) = dict.get(recovered, "downtime_ms")
  assert unwrap(int.parse(downtime)) >= 0

  let _ = await_request(fixture, 1, is_ticker_subscribe("BTC/USD", _))
  process.send(second.control, Send(ticker_json("BTC/USD", 101)))
  let _ = await_price(store, 101.0, 100)

  // These could already be in the mailbox when the old worker exits.
  list.each(
    [
      ConnectionEvent(
        connection.Received(TickerResponse(
          "BTC/USD",
          positive_float.from_float_unsafe(999.0),
          1_794_146_160_999,
        )),
      ),
      ConnectionEvent(
        connection.Received(TickerSubscribeConfirmation("BTC/USD", 0)),
      ),
      ConnectionEvent(connection.Failed("late failure")),
      DiscoveryDeadlineReached,
      ReconnectDelayElapsed,
      StabilityIntervalElapsed,
    ],
    fn(event) { process.send(client.data.subject, GenerationEvent(0, event)) },
  )

  process.send(client.data.subject, Unsubscribe("BTC/USD"))
  process.send(client.data.subject, Subscribe("ETH/USD"))
  let assert TickerSubscribe(["ETH/USD"], _) = next_request(fixture, 1)

  let assert Ok(current) = price_store.get_price(store, "BTC/USD")
  assert current.price == positive_float.from_float_unsafe(101.0)
  assert process.receive(fixture.opened, 0) == Error(Nil)

  process.send(client.data.subject, Unsubscribe("BTC/USD"))
  let _ =
    await_request(fixture, 1, fn(req) { req == TickerUnsubscribe(["BTC/USD"]) })

  assert receive_session_log(logs, session_pid, time.monotonic_time_ms())
    == Error(Nil)
  assert process.is_alive(second.pid)
}

pub fn abrupt_close_reconnects_and_client_shutdown_cleans_up_workers_test() {
  use fixture, url <- with_server([])
  use client, first, ready <- with_client(fixture, url, config())

  process.kill(first.pid)
  let _ = await_open(fixture, 1)
  let _ = await_ready(ready, client.pid, 1)

  let assert [worker] = monitored_processes(client.pid)
  let assert [socket] = linked_processes(worker)

  stop_process(client.pid)

  await_dead(worker, 100)
  await_dead(socket, 100)
  let assert Error(exception.Errored(_)) =
    exception.rescue(fn() {
      price_store.get_price(client.data.price_store, "BTC/USD")
    })
  let assert Error(exception.Errored(_)) =
    exception.rescue(fn() { pairs.count(client.data.pair_store) })
}

pub fn worker_reports_socket_failure_before_its_own_normal_exit_test() {
  use _, url <- with_server([])
  let events = process.new_subject()
  let worker =
    connection.start(
      process.self(),
      process.send(events, _),
      logger.new(),
      url,
      500,
      config().inactivity_timeout_ms,
      connection.send_text,
    )
  use <- exception.defer(fn() { stop_process(worker) })

  let assert Ok(connection.Connected(socket)) = process.receive(events, 1000)

  connection.send(
    socket,
    kraken_request.KrakenRequest(
      kraken_request.Subscribe,
      kraken_request.Instruments,
      None,
    ),
  )
  let assert Ok(connection.Received(response.InstrumentSnapshot(_))) =
    process.receive(events, 1000)

  let assert [socket_pid] = linked_processes(worker)
  process.kill(socket_pid)

  assert process.receive(events, 1000) == Ok(connection.Failed("Killed"))
  await_dead(worker, 100)
}

pub fn malformed_and_ignored_messages_do_not_interrupt_connection_test() {
  use fixture, url <- with_server([])
  let events = process.new_subject()
  let logs = process.new_subject()
  let worker =
    connection.start(
      process.self(),
      process.send(events, _),
      logger.new_with_sink(glight.Warning, process.send(logs, _)),
      url,
      500,
      config().inactivity_timeout_ms,
      connection.send_text,
    )
  use <- exception.defer(fn() { stop_process(worker) })

  let opened = await_open(fixture, 0)
  let assert Ok(connection.Connected(_)) = process.receive(events, 1000)

  let invalid_json = "{not-json"
  let invalid_snapshot =
    "{\"channel\":\"instrument\",\"type\":\"snapshot\",\"data\":{}}"
  list.each(
    [
      "{\"channel\":\"heartbeat\"}",
      "{\"channel\":\"status\",\"type\":\"update\"}",
      "{\"method\":\"unsubscribe\",\"success\":true}",
      "{\"method\":\"subscribe\",\"success\":true,\"result\":{\"channel\":\"instrument\"}}",
      invalid_json,
      invalid_snapshot,
      instrument_snapshot(),
    ],
    fn(text) { process.send(opened.control, Send(text)) },
  )

  let assert Ok(connection.Received(response.InstrumentSnapshot(_))) =
    process.receive(events, 1000)

  // The snapshot arrives after the socket handles the preceding frames.
  list.each([invalid_json, invalid_snapshot], fn(text) {
    let LogEntry(level, message, fields) = unwrap(process.receive(logs, 0))
    assert level == glight.Warning
    assert message == "Unable to decode Kraken response"
    assert dict.get(fields, "response") == Ok(text)
    let assert Ok(reason) = dict.get(fields, "reason")
    assert reason != ""
  })
  assert process.receive(logs, 0) == Error(Nil)

  assert process.receive(events, 0) == Error(Nil)
  assert process.is_alive(worker)
  assert process.is_alive(opened.pid)
}

pub fn outage_subscription_changes_determine_what_is_replayed_test() {
  use fixture, url <- with_server([Accept(True), Reject, Reject])
  use client, first, ready <- with_client(fixture, url, config())

  process.send(client.data.subject, Subscribe("BTC/USD"))
  let _ = await_request(fixture, 0, is_ticker_subscribe("BTC/USD", _))

  process.send(first.control, Close)
  let _ = await_attempt(fixture, 1)

  process.send(client.data.subject, Unsubscribe("BTC/USD"))
  process.send(client.data.subject, Subscribe("ETH/USD"))
  process.send(client.data.subject, Subscribe("ETH/USD"))
  process.send(client.data.subject, Unsubscribe("ETH/USD"))

  let _ = await_open(fixture, 3)

  let _ = await_ready(ready, client.pid, 3)
  let _ = await_request(fixture, 3, fn(req) { req == InstrumentSubscribe })
  let assert #(3, TickerSubscribe(["ETH/USD"], _)) =
    unwrap(process.receive(fixture.requests, 1000))

  process.send(client.data.subject, Unsubscribe("ETH/USD"))
  let _ =
    await_request(fixture, 3, fn(req) { req == TickerUnsubscribe(["ETH/USD"]) })

  assert process.is_alive(client.pid)
}

pub fn repeated_handshake_failures_back_off_and_cap_with_jitter_test() {
  let logs = process.new_subject()
  let client_logger = logger.new_with_sink(glight.Info, process.send(logs, _))
  let delays = process.new_subject()
  let cfg =
    session.Config(..config(), jitter_ms: fn() {
      process.send(delays, time.monotonic_time_ms())
      5
    })

  use fixture, url <- with_server([
    Accept(True),
    Reject,
    Reject,
    Reject,
    Reject,
  ])
  use client <- start_client_with_logger(url, cfg, client_logger)
  let first = await_open(fixture, 0)
  let _ = await_attempt(fixture, 0)
  let session_pid = string.inspect(client.pid)
  let _ =
    await_session_log(
      logs,
      session_pid,
      glight.Info,
      "Kraken connection ready",
      0,
    )

  process.send(first.control, Close)

  list.each([#(0, 35), #(1, 65), #(2, 125), #(3, 125), #(4, 125)], fn(expected) {
    let #(generation, delay_ms) = expected
    let reason = await_retry_logs(logs, session_pid, generation, delay_ms)
    case generation {
      0 -> {
        assert reason == "Normal"
      }
      _ -> {
        assert string.contains(reason, "503")
      }
    }

    let assert Ok(scheduled) = process.receive(delays, 2000)
    let #(attempt, attempted) = unwrap(process.receive(fixture.attempts, 2000))

    assert attempt == generation + 1
    assert attempted - scheduled >= delay_ms - 1
    assert attempted - scheduled < delay_ms + 80
  })

  let _ = await_open(fixture, 5)
  let _ =
    await_session_log(
      logs,
      session_pid,
      glight.Info,
      "Kraken connection ready",
      5,
    )
  Nil
}

pub fn stable_connection_resets_retry_delay_test() {
  let delays = process.new_subject()
  let cfg =
    session.Config(..config(), stable_connection_ms: 150, jitter_ms: fn() {
      process.send(delays, time.monotonic_time_ms())
      0
    })

  use fixture, url <- with_server([Accept(True), Reject])
  use client, first, ready <- with_client(fixture, url, cfg)
  let _ = await_attempt(fixture, 0)

  process.send(first.control, Close)
  let _ = await_attempt(fixture, 1)
  let second = await_open(fixture, 2)
  let _ = await_attempt(fixture, 2)

  let _ = unwrap(process.receive(delays, 1000))
  let _ = unwrap(process.receive(delays, 1000))

  let _ = await_ready(ready, client.pid, 2)
  process.sleep(cfg.stable_connection_ms + 100)

  process.send(second.control, Close)
  let assert Ok(scheduled) = process.receive(delays, 1000)
  let attempted = await_attempt(fixture, 3)

  assert attempted - scheduled >= 29
  assert attempted - scheduled < 100
}

pub fn instrument_update_does_not_complete_discovery_test() {
  use fixture, url <- with_server([Accept(False)])
  let cfg = session.Config(..config(), discovery_timeout_ms: 150)
  use client <- start_client(url, cfg)

  let first = await_open(fixture, 0)
  let _ = await_request(fixture, 0, fn(req) { req == InstrumentSubscribe })
  process.send(
    first.control,
    Send(instrument_json("update", [#("BTC/USD", "online")])),
  )
  let _ = await_open(fixture, 1)

  assert process.is_alive(client.pid)
}

pub fn heartbeats_do_not_extend_the_instrument_snapshot_deadline_test() {
  let logs = process.new_subject()
  let client_logger = logger.new_with_sink(glight.Info, process.send(logs, _))
  let cfg =
    session.Config(..inactivity_test_config(), discovery_timeout_ms: 700)
  use fixture, url <- with_server([Accept(False)])
  use client <- start_client_with_logger(url, cfg, client_logger)

  let first = await_open(fixture, 0)
  assert next_request(fixture, 0) == InstrumentSubscribe
  send_periodic_text(first, heartbeat)

  let reason = await_retry_logs(logs, string.inspect(client.pid), 0, 30)
  assert reason == "Kraken instrument snapshot deadline exceeded"
  let _ = await_open(fixture, 1)
  let _ = await_ready(logs, client.pid, 1)
}

pub fn send_failure_reconnects_without_recreating_price_store_test() {
  use fixture, url <- with_server([])
  let created = process.new_subject()
  let cfg =
    session.Config(..config(), send_text: fn(_, _) {
      Error("simulated transport failure")
    })

  let assert Ok(client) =
    session.start(
      logger.new(),
      fn() {
        process.send(created, Nil)
        unwrap(price_store.new())
      },
      url,
      cfg,
    )
  use <- exception.defer(fn() { stop_process(client.pid) })

  let _ = await_open(fixture, 0)
  let _ = await_open(fixture, 1)

  assert process.receive(created, 1000) == Ok(Nil)
  assert process.receive(created, 0) == Error(Nil)
  assert process.is_alive(client.pid)
}

fn with_server(plans, run) {
  let fixture =
    Fixture(
      opened: process.new_subject(),
      requests: process.new_subject(),
      attempts: process.new_subject(),
    )
  let sequence = start_connection_sequence(plans)

  use <- exception.defer(fn() { stop_process(sequence.pid) })

  let ready = process.new_subject()
  let handler = fn(req) {
    handle_connection_attempt(req, sequence.data, fixture)
  }

  let assert Ok(server) =
    handler
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
    |> mist.start

  use <- exception.defer(fn() { stop_process(server.pid) })

  let port = unwrap(process.receive(ready, 1000))
  let url = "http://127.0.0.1:" <> int.to_string(port) <> "/ws"

  run(fixture, url)
}

fn start_connection_sequence(plans) {
  actor.new(#(0, plans))
  |> actor.on_message(fn(state, message) {
    let NextAttempt(reply) = message
    let #(attempt, plans) = state
    let #(plan, remaining) = case plans {
      [] -> #(Accept(True), [])
      [plan, ..rest] -> #(plan, rest)
    }

    process.send(reply, #(attempt, plan))
    actor.continue(#(attempt + 1, remaining))
  })
  |> actor.start
  |> unwrap
}

fn handle_connection_attempt(req, sequence, fixture: Fixture) {
  let #(attempt, plan) = process.call(sequence, 1000, NextAttempt)
  process.send(fixture.attempts, #(attempt, time.monotonic_time_ms()))

  case plan {
    Reject ->
      http_response.new(503)
      |> http_response.set_body(mist.Bytes(bytes_tree.new()))

    Accept(snapshot) -> accept_connection(req, fixture, attempt, snapshot, True)

    ManualTickers -> accept_connection(req, fixture, attempt, True, False)

    DelayedAccept(delay_ms) -> {
      process.sleep(delay_ms)
      accept_connection(req, fixture, attempt, True, True)
    }
  }
}

fn accept_connection(req, fixture: Fixture, attempt, snapshot, auto_tickers) {
  mist.websocket(
    req,
    on_init: fn(_) {
      let control = process.new_subject()
      process.send(fixture.opened, Opened(attempt, control, process.self()))

      let selector =
        process.new_selector()
        |> process.select(control)

      #(Nil, Some(selector))
    },
    handler: fn(state, message, socket) {
      case message {
        mist.Custom(Send(text)) -> {
          send_frame(socket, text)
          mist.continue(state)
        }

        mist.Custom(Close) -> mist.stop()

        mist.Text(text) -> {
          let request = unwrap(json.parse(text, request_decoder()))
          process.send(fixture.requests, #(attempt, request))

          respond_to_request(socket, request, attempt, snapshot, auto_tickers)
          mist.continue(state)
        }

        _ -> mist.continue(state)
      }
    },
    on_close: fn(_) { Nil },
  )
}

fn respond_to_request(socket, request, attempt, snapshot, auto_tickers) {
  case request {
    InstrumentSubscribe if snapshot -> send_frame(socket, instrument_snapshot())

    TickerSubscribe(symbols, id) if auto_tickers ->
      list.each(symbols, fn(symbol) {
        send_frame(socket, ticker_confirmation_json(symbol, id))

        // Delay the recovery quote until tests explicitly request it.
        case attempt {
          0 -> send_frame(socket, ticker_json(symbol, 100))
          _ -> Nil
        }
      })

    _ -> Nil
  }
}

fn start_client(url, cfg, run) {
  start_client_with_logger(url, cfg, logger.new(), run)
}

fn start_client_with_logger(url, cfg, client_logger, run) {
  let assert Ok(client) =
    session.start(client_logger, fn() { unwrap(price_store.new()) }, url, cfg)
  use <- exception.defer(fn() { stop_process(client.pid) })
  run(client)
}

fn with_client(fixture, url, cfg, run) {
  let ready = process.new_subject()
  let client_logger =
    logger.new_with_sink(glight.Info, fn(entry) {
      case entry.message {
        "Kraken connection ready" -> process.send(ready, entry)
        _ -> Nil
      }
    })

  use client <- start_client_with_logger(url, cfg, client_logger)
  let opened = await_open(fixture, 0)
  let _ = await_ready(ready, client.pid, 0)
  run(client, opened, ready)
}

fn await_ready(ready, pid, generation) {
  await_session_log(
    ready,
    string.inspect(pid),
    glight.Info,
    "Kraken connection ready",
    generation,
  )
}

fn assert_periodic_text_keeps_socket_open(
  fixture: Fixture,
  opened: Opened,
  text: String,
) -> Nil {
  send_periodic_text(opened, text)
  // Wait beyond the inactivity window while frames arrive every 100 ms.
  assert process.receive(fixture.opened, 800) == Error(Nil)
  assert process.is_alive(opened.pid)
  assert process.receive(fixture.requests, 0) == Error(Nil)
}

fn send_periodic_text(opened: Opened, text: String) -> Nil {
  [0, 100, 200, 300, 400, 500, 600, 700]
  |> list.each(fn(delay_ms) {
    let _ = process.send_after(opened.control, delay_ms, Send(text))
    Nil
  })
}

fn request_decoder() {
  use method <- decode.field("method", decode.string)
  case method {
    "subscribe" | "unsubscribe" -> {
      use channel <- decode.subfield(["params", "channel"], decode.string)
      case channel, method {
        "instrument", "subscribe" -> decode.success(InstrumentSubscribe)
        "instrument", _ -> decode.success(InstrumentUnsubscribe)
        _, _ -> {
          use symbols <- decode.subfield(
            ["params", "symbol"],
            decode.list(decode.string),
          )
          case method {
            "subscribe" -> {
              use id <- decode.field("req_id", decode.int)
              decode.success(TickerSubscribe(symbols, id))
            }
            _ -> decode.success(TickerUnsubscribe(symbols))
          }
        }
      }
    }

    _ -> decode.success(UnexpectedMethod(method))
  }
}

fn is_ticker_subscribe(symbol, request) {
  case request {
    TickerSubscribe([requested], _) -> requested == symbol
    _ -> False
  }
}

fn next_request(fixture: Fixture, attempt: Int) -> Request {
  let #(actual, request) = unwrap(process.receive(fixture.requests, 2000))
  assert actual == attempt
  request
}

fn await_request(fixture: Fixture, attempt, matches) {
  let #(actual, request) = unwrap(process.receive(fixture.requests, 2000))
  case actual == attempt && matches(request) {
    True -> request
    False -> await_request(fixture, attempt, matches)
  }
}

fn await_open(fixture: Fixture, attempt) {
  let opened = unwrap(process.receive(fixture.opened, 2000))
  case opened.attempt == attempt {
    True -> opened
    False -> await_open(fixture, attempt)
  }
}

fn await_attempt(fixture: Fixture, attempt) {
  let #(actual, timestamp) = unwrap(process.receive(fixture.attempts, 2000))
  case actual == attempt {
    True -> timestamp
    False -> await_attempt(fixture, attempt)
  }
}

fn await_retry_logs(
  logs: Subject(LogEntry),
  session_pid: String,
  generation: Int,
  delay_ms: Int,
) -> String {
  let lost =
    await_session_log(
      logs,
      session_pid,
      glight.Warning,
      "Kraken connection lost",
      generation,
    )
  let assert Ok(reason) = dict.get(lost, "reason")
  let retry =
    await_session_log(
      logs,
      session_pid,
      glight.Warning,
      "Retrying Kraken connection",
      generation,
    )
  assert dict.get(retry, "delay_ms") == Ok(int.to_string(delay_ms))
  reason
}

fn await_session_log(
  logs: Subject(LogEntry),
  session_pid: String,
  level: glight.LogLevel,
  message: String,
  generation: Int,
) -> Dict(String, String) {
  let deadline = time.monotonic_time_ms() + 2000
  let LogEntry(actual_level, actual_message, fields) =
    unwrap(receive_session_log(logs, session_pid, deadline))

  assert actual_level == level
  assert actual_message == message
  assert dict.get(fields, "generation") == Ok(int.to_string(generation))
  fields
}

fn receive_session_log(
  logs: Subject(LogEntry),
  session_pid: String,
  deadline: Int,
) -> Result(LogEntry, Nil) {
  let remaining = int.max(0, deadline - time.monotonic_time_ms())
  case process.receive(logs, remaining) {
    Ok(entry) ->
      case dict.get(entry.fields, "pid") == Ok(session_pid) {
        True -> Ok(entry)
        False -> receive_session_log(logs, session_pid, deadline)
      }
    Error(Nil) -> Error(Nil)
  }
}

fn await_price(store, expected, retries) {
  await_symbol_price(store, "BTC/USD", expected, retries)
}

fn await_pair(store, symbol, expected, retries) {
  case pairs.exists(store, symbol) == expected {
    True -> Nil
    False -> {
      assert retries > 0
      process.sleep(5)
      await_pair(store, symbol, expected, retries - 1)
    }
  }
}

fn await_symbol_price(store, symbol, expected, retries) {
  let price = positive_float.from_float_unsafe(expected)
  case price_store.get_price(store, symbol) {
    Ok(entry) if entry.price == price -> entry
    _ -> {
      assert retries > 0
      process.sleep(5)
      await_symbol_price(store, symbol, expected, retries - 1)
    }
  }
}

fn await_dead(pid, retries) {
  case process.is_alive(pid) {
    True -> {
      assert retries > 0
      process.sleep(5)
      await_dead(pid, retries - 1)
    }
    False -> Nil
  }
}

fn stop_process(pid) {
  process.unlink(pid)
  let monitor = process.monitor(pid)
  process.kill(pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  Nil
}

fn unwrap(value) {
  let assert Ok(value) = value
  value
}

fn send_frame(socket, text) {
  let assert Ok(_) = mist.send_text_frame(socket, text)
  Nil
}

fn ticker_confirmation_json(symbol, id) {
  "{\"method\":\"subscribe\",\"success\":true,\"req_id\":"
  <> int.to_string(id)
  <> ",\"result\":{\"channel\":\"ticker\",\"symbol\":\""
  <> symbol
  <> "\"}}"
}

fn ticker_json(symbol, price) {
  ticker_json_with_timestamp(symbol, price, "2026-11-08T13:56:00.550875Z")
}

fn ticker_json_with_timestamp(symbol, price, timestamp) {
  "{\"channel\":\"ticker\",\"type\":\"update\",\"data\":[{\"symbol\":\""
  <> symbol
  <> "\",\"last\":"
  <> int.to_string(price)
  <> ",\"timestamp\":\""
  <> timestamp
  <> "\"}]}"
}

fn instrument_json(kind, instruments) {
  json.object([
    #("channel", json.string("instrument")),
    #("type", json.string(kind)),
    #(
      "data",
      json.object([
        #(
          "pairs",
          json.array(instruments, fn(instrument) {
            let #(symbol, status) = instrument
            json.object([
              #("symbol", json.string(symbol)),
              #("status", json.string(status)),
            ])
          }),
        ),
      ]),
    ),
  ])
  |> json.to_string
}

fn instrument_snapshot() {
  instrument_json("snapshot", [#("BTC/USD", "online"), #("ETH/USD", "online")])
}

@external(erlang, "process_test_ffi", "monitored_processes")
fn monitored_processes(pid: Pid) -> List(Pid)

@external(erlang, "process_test_ffi", "linked_processes")
fn linked_processes(pid: Pid) -> List(Pid)
