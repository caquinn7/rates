import exception
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/response as http_response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import mist
import server/integrations/kraken/internal/connection
import server/integrations/kraken/internal/request as kraken_request
import server/integrations/kraken/internal/response.{
  TickerResponse, TickerSubscribeConfirmation,
}
import server/integrations/kraken/internal/session.{
  ConnectionEvent, DiscoveryDeadlineReached, GenerationEvent,
  PingIntervalElapsed, PongDeadlineReached, ReconnectDelayElapsed,
  StabilityIntervalElapsed, Subscribe, Unsubscribe,
}
import server/integrations/kraken/pairs
import server/integrations/kraken/price_store
import server/utils/logger
import server/utils/time
import shared/numbers/positive_float

type PongMode {
  Echo
  Silent
  WrongId
}

type Plan {
  Accept(PongMode, snapshot: Bool)
  Reject
  DelayedAccept(Int)
}

type Control {
  Send(String)
  Close
}

pub type Request {
  InstrumentSubscribe
  InstrumentUnsubscribe
  TickerSubscribe(List(String))
  TickerUnsubscribe(List(String))
  Ping(Int)
}

type Opened {
  Opened(attempt: Int, control: Subject(Control), pid: Pid)
}

type Fixture {
  Fixture(
    opened: Subject(Opened),
    requests: Subject(#(Int, Request)),
    attempts: Subject(#(Int, Int)),
  )
}

type NextAttempt {
  NextAttempt(Subject(#(Int, Plan)))
}

fn config() {
  session.Config(
    ..session.default_config(),
    connect_timeout_ms: 500,
    ping_interval_ms: 80,
    pong_timeout_ms: 40,
    discovery_timeout_ms: 500,
    stable_connection_ms: 10_000,
    retry_base_ms: 30,
    retry_max_ms: 120,
    jitter_ms: fn() { 0 },
  )
}

/// Run application WebSocket tests against the same scripted Kraken endpoint.
pub fn with_kraken(run) {
  use fixture, url <- with_server([])
  use client, _ <- with_client(fixture, url, config())
  run(client, fixture.requests)
}

pub fn idle_socket_sends_correlated_pings_without_ticker_subscriptions_test() {
  use fixture, url <- with_server([])
  use client, _ <- with_client(fixture, url, config())

  let assert Ping(first) = await_request(fixture, 0, is_ping)
  let assert Ping(second) = await_request(fixture, 0, is_ping)
  let assert Ping(third) = await_request(fixture, 0, is_ping)

  assert second == first + 1
  assert third == second + 1

  assert process.is_alive(client.pid)
  assert process.receive(fixture.opened, 0) == Error(Nil)
}

pub fn missing_pong_reconnects_even_while_other_messages_arrive_test() {
  use fixture, url <- with_server([Accept(Silent, True)])
  use client, first <- with_client(fixture, url, config())

  let assert Ping(_) = await_request(fixture, 0, is_ping)
  process.send(first.control, Send("{\"channel\":\"heartbeat\"}"))
  let second = await_open(fixture, 1)

  assert process.is_alive(client.pid)
  assert !process.is_alive(first.pid)
  assert process.is_alive(second.pid)
}

pub fn wrong_pong_id_does_not_prevent_reconnect_test() {
  use fixture, url <- with_server([Accept(WrongId, True)])
  use client, _ <- with_client(fixture, url, config())

  let _ = await_open(fixture, 1)

  assert process.is_alive(client.pid)
}

pub fn late_pong_from_previous_connection_cannot_satisfy_new_ping_test() {
  use fixture, url <- with_server([Accept(Silent, True), Accept(Silent, True)])
  use client, _ <- with_client(fixture, url, config())

  let assert Ping(old_id) = await_request(fixture, 0, is_ping)

  let _ = await_open(fixture, 1)
  let assert Ping(new_id) = await_request(fixture, 1, is_ping)
  assert new_id != old_id

  process.send(
    client.data,
    GenerationEvent(
      0,
      ConnectionEvent(connection.Received(response.Pong(old_id))),
    ),
  )
  process.send(
    client.data,
    GenerationEvent(
      1,
      ConnectionEvent(connection.Received(response.Pong(old_id))),
    ),
  )
  let _ = await_open(fixture, 2)

  assert process.is_alive(client.pid)
}

pub fn stale_deadline_cannot_end_new_instrument_discovery_test() {
  use fixture, url <- with_server([Accept(Echo, True), Accept(Echo, False)])
  use client, first <- with_client(fixture, url, config())

  process.send(first.control, Close)
  let recovered = await_open(fixture, 1)
  let _ = await_request(fixture, 1, fn(req) { req == InstrumentSubscribe })

  process.send(client.data, GenerationEvent(0, DiscoveryDeadlineReached))
  let assert Some(snapshot) =
    unwrap(json.parse(instrument_snapshot, response.decoder()))

  // Send both events from this process so the stale deadline is handled first.
  process.send(
    client.data,
    GenerationEvent(1, ConnectionEvent(connection.Received(snapshot))),
  )

  let _ = await_request(fixture, 1, fn(req) { req == InstrumentUnsubscribe })
  assert process.is_alive(client.pid)
  assert process.is_alive(recovered.pid)
  assert process.receive(fixture.opened, 0) == Error(Nil)
}

pub fn repeated_reconnects_leave_only_the_current_worker_and_socket_test() {
  use fixture, url <- with_server([])
  use client, first <- with_client(fixture, url, config())

  let _ =
    list.fold([1, 2, 3], first, fn(previous, attempt) {
      let assert [worker] = monitored_processes(client.pid)
      let assert [socket] = linked_processes(worker)

      process.send(previous.control, Close)
      let opened = await_open(fixture, attempt)
      let _ =
        await_request(fixture, attempt, fn(req) { req == InstrumentUnsubscribe })

      await_dead(worker, 100)
      await_dead(socket, 100)
      let assert [_] = monitored_processes(client.pid)

      opened
    })

  assert process.is_alive(client.pid)
}

pub fn unexpected_worker_exit_reconnects_and_preserves_subscription_state_test() {
  use fixture, url <- with_server([])
  use client, _ <- with_client(fixture, url, config())

  process.send(client.data, Subscribe("BTC/USD"))
  let _ =
    await_request(fixture, 0, fn(req) { req == TickerSubscribe(["BTC/USD"]) })

  let assert Ok(store) = price_store.get_store()
  let cached = await_price(store, 100.0, 100)
  assert cached.timestamp == 1_794_146_160_550
  assert price_store.get_price(store, "BTC/USD") == Ok(cached)

  let assert [worker] = monitored_processes(client.pid)
  let assert [socket] = linked_processes(worker)

  // An unexpected worker exit provides no connection.Failed notification.
  process.kill(worker)
  let recovered = await_open(fixture, 1)
  let _ =
    await_request(fixture, 1, fn(req) { req == TickerSubscribe(["BTC/USD"]) })

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

  process.send(client.data, Unsubscribe("BTC/USD"))
  let _ =
    await_request(fixture, 1, fn(req) { req == TickerUnsubscribe(["BTC/USD"]) })
}

pub fn invalid_ticker_timestamps_preserve_cached_prices_test() {
  use fixture, url <- with_server([])
  use client, opened <- with_client(fixture, url, config())

  process.send(client.data, Subscribe("BTC/USD"))
  let _ =
    await_request(fixture, 0, fn(req) { req == TickerSubscribe(["BTC/USD"]) })
  process.send(client.data, Subscribe("ETH/USD"))
  let _ =
    await_request(fixture, 0, fn(req) { req == TickerSubscribe(["ETH/USD"]) })

  let assert Ok(store) = price_store.get_store()
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

pub fn shutdown_during_reconnect_handshake_cleans_up_the_attempt_test() {
  use fixture, url <- with_server([Accept(Echo, True), DelayedAccept(200)])
  use client, first <- with_client(fixture, url, config())

  process.send(first.control, Close)
  let _ = await_attempt(fixture, 1)

  let assert [worker] = monitored_processes(client.pid)
  let assert [socket] = linked_processes(worker)

  stop_process(client.pid)

  await_dead(worker, 150)
  await_dead(socket, 150)
}

pub fn normal_close_preserves_cache_counts_and_ignores_old_connection_events_test() {
  use fixture, url <- with_server([])
  use client, first <- with_client(fixture, url, config())

  process.send(client.data, Subscribe("BTC/USD"))
  process.send(client.data, Subscribe("BTC/USD"))
  let _ =
    await_request(fixture, 0, fn(req) { req == TickerSubscribe(["BTC/USD"]) })

  let assert Ok(store) = price_store.get_store()
  let old = await_price(store, 100.0, 100)
  let assert [first_worker] = monitored_processes(client.pid)
  let assert [first_socket] = linked_processes(first_worker)

  process.send(first.control, Close)
  let second = await_open(fixture, 1)

  assert process.is_alive(client.pid)
  assert !process.is_alive(first_worker)
  assert !process.is_alive(first_socket)
  assert price_store.get_price(store, "BTC/USD") == Ok(old)

  let _ =
    await_request(fixture, 1, fn(req) { req == TickerSubscribe(["BTC/USD"]) })
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
        connection.Received(TickerSubscribeConfirmation("BTC/USD")),
      ),
      ConnectionEvent(connection.Failed("late failure")),
      PongDeadlineReached(0),
      PingIntervalElapsed,
      DiscoveryDeadlineReached,
      ReconnectDelayElapsed,
      StabilityIntervalElapsed,
    ],
    fn(event) { process.send(client.data, GenerationEvent(0, event)) },
  )

  process.send(client.data, Unsubscribe("BTC/USD"))
  let _ = await_request(fixture, 1, is_ping)

  let assert Ok(current) = price_store.get_price(store, "BTC/USD")
  assert current.price == positive_float.from_float_unsafe(101.0)
  assert process.receive(fixture.opened, 0) == Error(Nil)

  process.send(client.data, Unsubscribe("BTC/USD"))
  let _ =
    await_request(fixture, 1, fn(req) { req == TickerUnsubscribe(["BTC/USD"]) })

  assert process.is_alive(second.pid)
}

pub fn abrupt_close_reconnects_and_client_shutdown_cleans_up_workers_test() {
  use fixture, url <- with_server([])
  use client, first <- with_client(fixture, url, config())

  process.kill(first.pid)
  let _ = await_open(fixture, 1)
  let _ = await_request(fixture, 1, fn(req) { req == InstrumentUnsubscribe })

  let assert [worker] = monitored_processes(client.pid)
  let assert [socket] = linked_processes(worker)

  stop_process(client.pid)

  await_dead(worker, 100)
  await_dead(socket, 100)
  assert price_store.get_store() == Error(Nil)
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
      connection.send_text,
    )
  use <- exception.defer(fn() { stop_process(worker) })

  let assert Ok(connection.Connected(socket)) = process.receive(events, 1000)

  connection.send(socket, kraken_request.Ping(42))
  assert process.receive(events, 1000)
    == Ok(connection.Received(response.Pong(42)))

  let assert [socket_pid] = linked_processes(worker)
  process.kill(socket_pid)

  assert process.receive(events, 1000) == Ok(connection.Failed("Killed"))
  await_dead(worker, 100)
}

pub fn malformed_and_ignored_messages_do_not_interrupt_connection_test() {
  use fixture, url <- with_server([])
  let events = process.new_subject()
  let worker =
    connection.start(
      process.self(),
      process.send(events, _),
      logger.new(),
      url,
      500,
      connection.send_text,
    )
  use <- exception.defer(fn() { stop_process(worker) })

  let opened = await_open(fixture, 0)
  let assert Ok(connection.Connected(_)) = process.receive(events, 1000)

  list.each(
    [
      "{\"channel\":\"heartbeat\"}",
      "{\"channel\":\"status\",\"type\":\"update\"}",
      "{\"method\":\"unsubscribe\",\"success\":true}",
      "{\"method\":\"subscribe\",\"success\":true,\"result\":{\"channel\":\"instrument\"}}",
      "{\"channel\":\"instrument\",\"type\":\"update\",\"data\":{\"pairs\":[]}}",
      "{not-json",
      "{\"method\":\"pong\",\"req_id\":\"not an integer\"}",
      pong_json(42),
    ],
    fn(text) { process.send(opened.control, Send(text)) },
  )

  assert process.receive(events, 1000)
    == Ok(connection.Received(response.Pong(42)))
  assert process.receive(events, 0) == Error(Nil)
  assert process.is_alive(worker)
  assert process.is_alive(opened.pid)
}

pub fn outage_subscription_changes_determine_what_is_replayed_test() {
  use fixture, url <- with_server([Accept(Echo, True), Reject, Reject])
  use client, first <- with_client(fixture, url, config())

  process.send(client.data, Subscribe("BTC/USD"))
  let _ =
    await_request(fixture, 0, fn(req) { req == TickerSubscribe(["BTC/USD"]) })

  process.send(first.control, Close)
  let _ = await_attempt(fixture, 1)

  process.send(client.data, Unsubscribe("BTC/USD"))
  process.send(client.data, Subscribe("ETH/USD"))
  process.send(client.data, Subscribe("ETH/USD"))
  process.send(client.data, Unsubscribe("ETH/USD"))

  let _ = await_open(fixture, 3)

  // Subscription replay follows instrument unsubscribe on each new connection.
  let _ = await_request(fixture, 3, fn(req) { req == InstrumentUnsubscribe })
  let assert #(3, TickerSubscribe(["ETH/USD"])) =
    unwrap(process.receive(fixture.requests, 1000))

  process.send(client.data, Unsubscribe("ETH/USD"))
  let _ =
    await_request(fixture, 3, fn(req) { req == TickerUnsubscribe(["ETH/USD"]) })

  assert process.is_alive(client.pid)
}

pub fn repeated_handshake_failures_back_off_and_cap_with_jitter_test() {
  let delays = process.new_subject()
  let cfg =
    session.Config(..config(), jitter_ms: fn() {
      process.send(delays, time.monotonic_time_ms())
      5
    })

  use fixture, url <- with_server([
    Accept(Echo, True),
    Reject,
    Reject,
    Reject,
    Reject,
  ])
  use _, first <- with_client(fixture, url, cfg)
  let _ = await_attempt(fixture, 0)

  process.send(first.control, Close)

  list.each([35, 65, 125, 125, 125], fn(minimum) {
    let assert Ok(scheduled) = process.receive(delays, 2000)
    let #(_, attempted) = unwrap(process.receive(fixture.attempts, 2000))

    assert attempted - scheduled >= minimum - 1
    assert attempted - scheduled < minimum + 80
  })
}

pub fn stable_connection_resets_retry_delay_test() {
  let delays = process.new_subject()
  let cfg =
    session.Config(..config(), stable_connection_ms: 150, jitter_ms: fn() {
      process.send(delays, time.monotonic_time_ms())
      0
    })

  use fixture, url <- with_server([Accept(Echo, True), Reject])
  use _, first <- with_client(fixture, url, cfg)
  let _ = await_attempt(fixture, 0)

  process.send(first.control, Close)
  let _ = await_attempt(fixture, 1)
  let second = await_open(fixture, 2)
  let _ = await_attempt(fixture, 2)

  let _ = unwrap(process.receive(delays, 1000))
  let _ = unwrap(process.receive(delays, 1000))

  // More than 150ms of successful pings after the recovered snapshot.
  list.each([1, 2, 3], fn(_) {
    let _ = await_request(fixture, 2, is_ping)
    Nil
  })

  process.send(second.control, Close)
  let assert Ok(scheduled) = process.receive(delays, 1000)
  let attempted = await_attempt(fixture, 3)

  assert attempted - scheduled >= 29
  assert attempted - scheduled < 100
}

pub fn absent_instrument_snapshot_reconnects_test() {
  use fixture, url <- with_server([Accept(Echo, False)])
  let cfg = session.Config(..config(), discovery_timeout_ms: 150)
  use client <- start_client(url, cfg)

  let _ = await_open(fixture, 0)
  let _ = await_open(fixture, 1)

  assert process.is_alive(client.pid)
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

  use <- exception.defer(fn() {
    stop_process(sequence.pid)
    pairs.clear()
  })

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
      [] -> #(Accept(Echo, True), [])
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

    Accept(pong, snapshot) ->
      accept_connection(req, fixture, attempt, pong, snapshot)

    DelayedAccept(delay_ms) -> {
      process.sleep(delay_ms)
      accept_connection(req, fixture, attempt, Echo, True)
    }
  }
}

fn accept_connection(req, fixture: Fixture, attempt, pong, snapshot) {
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

          respond_to_request(socket, request, attempt, pong, snapshot)
          mist.continue(state)
        }

        _ -> mist.continue(state)
      }
    },
    on_close: fn(_) { Nil },
  )
}

fn respond_to_request(socket, request, attempt, pong, snapshot) {
  case request {
    InstrumentSubscribe if snapshot -> send_frame(socket, instrument_snapshot)

    Ping(id) ->
      case pong {
        Echo -> send_frame(socket, pong_json(id))
        WrongId -> send_frame(socket, pong_json(id + 1))
        Silent -> Nil
      }

    TickerSubscribe(symbols) ->
      list.each(symbols, fn(symbol) {
        send_frame(socket, ticker_confirmation_json(symbol))

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
  let assert Ok(client) =
    session.start(logger.new(), fn() { unwrap(price_store.new()) }, url, cfg)
  use <- exception.defer(fn() { stop_process(client.pid) })
  run(client)
}

fn with_client(fixture, url, cfg, run) {
  use client <- start_client(url, cfg)
  let opened = await_open(fixture, 0)
  let _ = await_request(fixture, 0, fn(req) { req == InstrumentUnsubscribe })
  run(client, opened)
}

fn request_decoder() {
  use method <- decode.field("method", decode.string)
  case method {
    "ping" -> {
      use id <- decode.field("req_id", decode.int)
      decode.success(Ping(id))
    }
    _ -> {
      use channel <- decode.subfield(["params", "channel"], decode.string)
      case channel, method {
        "instrument", "subscribe" -> decode.success(InstrumentSubscribe)
        "instrument", _ -> decode.success(InstrumentUnsubscribe)
        _, _ -> {
          use symbols <- decode.subfield(
            ["params", "symbol"],
            decode.list(decode.string),
          )
          decode.success(case method {
            "subscribe" -> TickerSubscribe(symbols)
            _ -> TickerUnsubscribe(symbols)
          })
        }
      }
    }
  }
}

fn is_ping(request) {
  case request {
    Ping(_) -> True
    _ -> False
  }
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

fn await_price(store, expected, retries) {
  await_symbol_price(store, "BTC/USD", expected, retries)
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

fn pong_json(id) {
  "{\"method\":\"pong\",\"req_id\":" <> int.to_string(id) <> "}"
}

fn ticker_confirmation_json(symbol) {
  "{\"method\":\"subscribe\",\"success\":true,\"result\":{\"channel\":\"ticker\",\"symbol\":\""
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

const instrument_snapshot =
  "{\"channel\":\"instrument\",\"type\":\"snapshot\",\"data\":{\"pairs\":[{\"symbol\":\"BTC/USD\",\"base\":\"BTC\",\"quote\":\"USD\"},{\"symbol\":\"ETH/USD\",\"base\":\"ETH\",\"quote\":\"USD\"}]}}"

@external(erlang, "kraken_recovery_test_ffi", "monitored_processes")
fn monitored_processes(pid: Pid) -> List(Pid)

@external(erlang, "kraken_recovery_test_ffi", "linked_processes")
fn linked_processes(pid: Pid) -> List(Pid)
