//// Maintains a Kraken session across WebSocket connections. Only connection
//// workers are replaced on failure; the session retains the protected ETS table
//// and client reference counts.

import gleam/bool
import gleam/erlang/process.{type Monitor, type Pid, type Subject, type Timer}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import server/integrations/kraken/internal/connection.{type SendText}
import server/integrations/kraken/internal/request.{
  Instruments, KrakenRequest, Ping, Tickers,
}
import server/integrations/kraken/internal/response.{
  type KrakenResponse, InstrumentsResponse, Pong, TickerResponse,
  TickerSubscribeConfirmation,
}
import server/integrations/kraken/internal/subscription_counter.{
  type SubscriptionCounter,
}
import server/integrations/kraken/pairs
import server/integrations/kraken/price_store.{type PriceStore}
import server/utils/logger.{type Logger}
import server/utils/time

/// Timing and transport settings for the Kraken session.
///
/// All durations are in milliseconds. `default_config` provides production
/// defaults; timings and injected functions can be overridden for tests.
pub type Config {
  Config(
    /// Timeout passed to each WebSocket handshake attempt. Initial failures are
    /// returned to the caller; failures after startup trigger reconnection.
    connect_timeout_ms: Int,
    /// Interval between ping checks, starting after the handshake. A new ping is
    /// sent only when no pong is outstanding.
    ping_interval_ms: Int,
    /// Maximum wait for a pong matching the outstanding ping's request ID.
    /// A missed deadline triggers reconnection.
    pong_timeout_ms: Int,
    /// Maximum wait for the instrument snapshot after the handshake.
    /// A missed deadline triggers reconnection.
    discovery_timeout_ms: Int,
    /// Time the connection must remain ready after instrument discovery before
    /// resetting the retry delay to `retry_base_ms`.
    stable_connection_ms: Int,
    /// Initial reconnect delay before jitter. Doubled on each retry until
    /// `retry_max_ms` is reached.
    retry_base_ms: Int,
    /// Maximum reconnect delay before jitter is added. The total scheduled
    /// delay can exceed this limit by the amount of jitter.
    retry_max_ms: Int,
    /// Called once per scheduled retry to produce extra delay. Must return a
    /// nonnegative number of milliseconds, added after capping the retry delay.
    jitter_ms: fn() -> Int,
    /// Sends encoded Kraken JSON as a WebSocket text message. Returning an error
    /// closes the socket and triggers reconnection. Injectable for transport tests.
    send_text: SendText,
  )
}

/// Returns production defaults using the connection adapter's text sender.
///
/// Uses a handshake timeout of 5 seconds, a ping interval of 20 seconds, and
/// pong and instrument snapshot deadlines of 10 seconds. Reconnect delays double
/// from 5 to 60 seconds, plus 0–1000 ms of random jitter. The retry delay resets
/// after the connection remains ready for 60 seconds.
pub fn default_config() -> Config {
  Config(
    connect_timeout_ms: 5000,
    ping_interval_ms: 20_000,
    pong_timeout_ms: 10_000,
    discovery_timeout_ms: 10_000,
    stable_connection_ms: 60_000,
    retry_base_ms: 5000,
    retry_max_ms: 60_000,
    jitter_ms: fn() { int.random(1001) },
    send_text: connection.send_text,
  )
}

/// Messages handled by the Kraken session to track client interest and manage
/// connection recovery.
pub type Message {
  /// Adds one client's interest in a symbol, retaining it through reconnects.
  /// The first interest is subscribed upstream once ready. Symbols excluded by
  /// the latest known instrument snapshot are ignored.
  Subscribe(String)

  /// Removes one client's interest in a symbol. Sends an upstream unsubscribe
  /// when ready and the last reference is removed. Untracked symbols are ignored.
  Unsubscribe(String)

  /// Confirms a monitored connection worker has exited so a retry can be
  /// scheduled. Only notifications matching the current worker's PID and
  /// monitor reference are handled.
  ///
  WorkerDown(process.Down)

  /// Wraps a connection or timer event with its connection attempt number.
  /// Events from a different connection attempt are ignored.
  GenerationEvent(generation: Int, event: Event)
}

/// Connection notifications and timer expirations for one connection attempt.
/// Wrapped in `GenerationEvent` so events from different attempts are ignored.
pub type Event {
  /// Forwards a successful handshake, decoded Kraken response, or connection
  /// failure from the connection worker.
  ConnectionEvent(connection.Event)

  /// Signals that the ping interval has elapsed. Sends a keepalive ping only
  /// while connected and no pong is outstanding.
  PingIntervalElapsed

  /// Signals that the deadline for the given ping request ID has been reached.
  /// Triggers reconnection only if that ping still awaits a matching pong.
  PongDeadlineReached(Int)

  /// Signals that the instrument snapshot deadline has been reached.
  /// Triggers reconnection only if instrument discovery is still in progress.
  DiscoveryDeadlineReached

  /// Signals that the connection has remained ready long enough to reset
  /// the retry delay to its configured base.
  StabilityIntervalElapsed

  /// Signals that the retry delay has elapsed. Starts the next connection
  /// attempt only while waiting to reconnect, incrementing its attempt number.
  ReconnectDelayElapsed
}

/// Connection lifecycle and the resources available in each phase.
/// Subscription interest and cached prices survive transitions between phases.
type Phase {
  /// Waiting for the worker to establish a WebSocket connection.
  /// A successful handshake starts instrument discovery.
  Connecting(Worker)

  /// The handshake has completed and the instrument snapshot is pending.
  /// Keepalive pings are active. Ticker subscriptions are sent after discovery
  /// establishes which symbols are supported.
  Discovering(Worker, connection.Socket)

  /// Instruments are known and ticker subscriptions can be managed on the socket.
  /// Incoming prices for confirmed subscriptions update the shared price store.
  Ready(Worker, connection.Socket)

  /// The connection has failed and worker shutdown has been requested.
  /// Retains the worker until its monitor confirms exit, then schedules a retry.
  Stopping(Worker)

  /// The previous worker has exited and the retry delay is running.
  /// No worker or socket is retained; the next attempt starts after the delay.
  WaitingToReconnect
}

/// Tracks the process responsible for one WebSocket connection attempt.
/// Its monitor confirms shutdown before the session schedules another attempt.
type Worker {
  Worker(
    /// Identifies the connection worker and allows it to be stopped on failure.
    pid: Pid,
    /// Paired with the PID to recognize this worker's exit notification and
    /// ignore unrelated or stale process notifications.
    monitor: Monitor,
  )
}

/// `process.Timer` handles tracked by the session for keepalive, discovery, and
/// recovery. A field is `None` when no timer of that kind is tracked. Handles
/// allow timers to be cancelled when a response arrives or the connection is lost.
type Timers {
  Timers(
    /// Timer for the next keepalive ping check while discovering or ready.
    ping: Option(Timer),
    /// Outstanding ping request ID and its pong deadline timer. Cleared when
    /// a matching pong arrives or the connection is lost.
    pong: Option(#(Int, Timer)),
    /// Deadline for the first instrument snapshot on the current connection.
    /// Cleared when discovery completes or the connection is lost.
    discovery: Option(Timer),
    /// Timer that resets retry backoff after the connection remains ready for
    /// the configured period. Cleared when it fires or the connection is lost.
    stable: Option(Timer),
  )
}

type State {
  State(
    self: Subject(Message),
    logger: Logger,
    price_store: PriceStore,
    url: String,
    config: Config,
    phase: Phase,
    generation: Int,
    supported_symbols: Option(Set(String)),
    subscriptions: SubscriptionCounter,
    timers: Timers,
    retry_delay_ms: Int,
    next_ping_id: Int,
    disconnected_at: Option(Int),
  )
}

/// Starts a Kraken session at `url` using the supplied timing and transport settings.
///
/// Waits for the initial WebSocket handshake, returning a startup error on failure
/// or timeout. After a successful handshake, calls `create_store` once inside the
/// session process so the session owns the newly created price store.
///
/// The successful start result contains the session PID and message subject.
/// Instrument discovery continues asynchronously; subscription interest received
/// during discovery is retained until the session is ready. Later connection
/// failures trigger automatic retries, preserving subscription interest and
/// cached prices with their original timestamps.
pub fn start(
  logger: Logger,
  create_store: fn() -> PriceStore,
  url: String,
  config: Config,
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(config.connect_timeout_ms + 1000, fn(self) {
    let worker = start_worker(self, logger, url, config, 0)

    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(WorkerDown)

    // Preserve the constructor's handshake/error contract and ETS ownership.
    use socket <- result.try(await_initial_connection(selector, config))

    let state =
      State(
        self:,
        logger:,
        price_store: create_store(),
        url:,
        config:,
        phase: Connecting(worker),
        generation: 0,
        supported_symbols: None,
        subscriptions: subscription_counter.new(),
        timers: empty_timers(),
        retry_delay_ms: config.retry_base_ms,
        next_ping_id: 0,
        disconnected_at: None,
      )

    state
    |> begin_discovery(worker, socket)
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    actor.continue(handle_message(state, message))
  })
  |> actor.start
}

fn await_initial_connection(selector, config: Config) {
  case process.selector_receive(selector, config.connect_timeout_ms + 500) {
    Ok(GenerationEvent(0, ConnectionEvent(connection.Connected(socket)))) ->
      Ok(socket)
    Ok(GenerationEvent(0, ConnectionEvent(connection.Failed(reason)))) ->
      Error(reason)
    Ok(WorkerDown(down)) -> Error(string.inspect(down))
    Ok(_) -> await_initial_connection(selector, config)
    Error(_) -> Error("Timed out waiting for Kraken handshake")
  }
}

/// Starts a connection worker owned by this session and monitors its process.
/// Forwards connection notifications to the session, tagging each with the given
/// connection attempt number so events from older attempts can be ignored.
/// Returns the worker PID and monitor used to detect its exit and begin recovery.
fn start_worker(
  self: Subject(Message),
  logger: Logger,
  url: String,
  config: Config,
  generation: Int,
) -> Worker {
  let pid =
    connection.start(
      process.self(),
      fn(event) {
        process.send(self, GenerationEvent(generation, ConnectionEvent(event)))
      },
      logger,
      url,
      config.connect_timeout_ms,
      config.send_text,
    )
  Worker(pid, process.monitor(pid))
}

/// Begins instrument discovery after a successful WebSocket handshake.
/// Requests the instrument snapshot, schedules the first keepalive ping check
/// and discovery deadline, and enters `Discovering` with the worker and socket.
/// When the first snapshot arrives, the session sends an instrument unsubscribe
/// and restores remaining ticker interest. This sequence repeats on each reconnect.
fn begin_discovery(
  state: State,
  worker: Worker,
  socket: connection.Socket,
) -> State {
  connection.send(socket, KrakenRequest(request.Subscribe, Instruments, None))

  let ping =
    schedule_event(state, state.config.ping_interval_ms, PingIntervalElapsed)

  let discovery =
    schedule_event(
      state,
      state.config.discovery_timeout_ms,
      DiscoveryDeadlineReached,
    )

  State(
    ..state,
    phase: Discovering(worker, socket),
    timers: Timers(..state.timers, ping: Some(ping), discovery: Some(discovery)),
  )
}

/// Handles subscription commands, worker exits, and connection or timer events.
/// Updates client interest across reconnects and schedules recovery when the
/// current worker exits. Ignores unrelated worker notifications and events from
/// a different connection attempt before dispatching accepted events to `handle_event`.
fn handle_message(state: State, message: Message) -> State {
  case message {
    Subscribe(symbol) -> subscribe(state, symbol)

    Unsubscribe(symbol) -> {
      let #(send_unsubscribe, subscriptions) =
        subscription_counter.remove_subscription(state.subscriptions, symbol)

      case state.phase, send_unsubscribe {
        Ready(_, socket), True ->
          connection.send(
            socket,
            KrakenRequest(request.Unsubscribe, Tickers([symbol]), None),
          )
        _, _ -> Nil
      }

      State(..state, subscriptions:)
    }

    WorkerDown(process.ProcessDown(monitor, pid, reason)) -> {
      case state.phase {
        Connecting(worker)
          | Discovering(worker, _)
          | Ready(worker, _)
          | Stopping(worker)
          if pid == worker.pid && monitor == worker.monitor
        -> {
          state
          |> disconnect(string.inspect(reason))
          |> schedule_reconnect
        }

        _ -> state
      }
    }

    WorkerDown(_) -> state

    GenerationEvent(generation, event) -> {
      use <- bool.guard(generation != state.generation, state)
      handle_event(state, event)
    }
  }
}

/// Handles connection notifications and timers for the current connection attempt.
/// Called after `handle_message` checks the attempt number. Applies events only
/// in the relevant phase: begins discovery, processes Kraken responses, checks
/// keepalive deadlines, resets retry backoff, or starts the next connection attempt.
/// Events that do not apply to the current phase or pending ping are ignored.
fn handle_event(state: State, event: Event) -> State {
  case event, state.phase {
    ConnectionEvent(event), phase -> {
      case event, phase {
        connection.Connected(socket), Connecting(worker) ->
          begin_discovery(state, worker, socket)

        connection.Failed(reason), Connecting(_)
        | connection.Failed(reason), Discovering(_, _)
        | connection.Failed(reason), Ready(_, _)
        -> disconnect(state, reason)

        connection.Received(message), Discovering(_, _)
        | connection.Received(message), Ready(_, _)
        -> receive_message(state, message)

        _, _ -> state
      }
    }

    PingIntervalElapsed, Discovering(_, socket)
    | PingIntervalElapsed, Ready(_, socket)
    -> {
      let next_ping =
        schedule_event(
          state,
          state.config.ping_interval_ms,
          PingIntervalElapsed,
        )
      let timers = Timers(..state.timers, ping: Some(next_ping))

      case state.timers.pong {
        Some(_) -> State(..state, timers:)
        None -> {
          let req_id = state.next_ping_id
          connection.send(socket, Ping(req_id))
          let deadline =
            schedule_event(
              state,
              state.config.pong_timeout_ms,
              PongDeadlineReached(req_id),
            )
          State(
            ..state,
            next_ping_id: req_id + 1,
            timers: Timers(..timers, pong: Some(#(req_id, deadline))),
          )
        }
      }
    }

    PongDeadlineReached(req_id), _ -> {
      case state.timers.pong {
        Some(#(expected, _)) if req_id == expected ->
          disconnect(state, "Kraken pong deadline exceeded")
        _ -> state
      }
    }

    DiscoveryDeadlineReached, Discovering(_, _) ->
      disconnect(state, "Kraken instrument snapshot deadline exceeded")

    StabilityIntervalElapsed, Ready(_, _) ->
      State(
        ..state,
        retry_delay_ms: state.config.retry_base_ms,
        timers: Timers(..state.timers, stable: None),
      )

    ReconnectDelayElapsed, WaitingToReconnect -> {
      let generation = state.generation + 1
      let worker =
        start_worker(
          state.self,
          state.logger,
          state.url,
          state.config,
          generation,
        )

      State(
        ..state,
        generation:,
        phase: Connecting(worker),
        timers: empty_timers(),
      )
    }

    _, _ -> state
  }
}

/// Registers interest in a symbol, ignoring symbols excluded by the latest known
/// instrument snapshot. Before the first snapshot, records interest without
/// checking support; discovery determines which subscriptions to send.
fn subscribe(state: State, symbol: String) -> State {
  case state.supported_symbols {
    Some(symbols) -> {
      use <- bool.guard(!set.contains(symbols, symbol), state)
      add_interest(state, symbol)
    }
    None -> add_interest(state, symbol)
  }
}

/// Increments the symbol's reference count. Sends a Kraken subscription only for
/// the first interest while ready; further interests share that subscription.
/// While not ready, records interest for replay after instrument discovery.
fn add_interest(state: State, symbol: String) -> State {
  let #(send_subscribe, subscriptions) =
    subscription_counter.add_subscription(state.subscriptions, symbol)

  case state.phase, send_subscribe {
    Ready(_, socket), True ->
      connection.send(
        socket,
        KrakenRequest(request.Subscribe, Tickers([symbol]), None),
      )
    _, _ -> Nil
  }

  State(..state, subscriptions:)
}

/// Applies decoded Kraken responses during instrument discovery or normal operation.
/// Matching pongs clear their deadline. Handling the first instrument snapshot
/// on each connection updates supported pairs, sends an instrument unsubscribe,
/// restores remaining ticker interest, and makes the session ready. Additional
/// instrument snapshots are ignored while ready.
/// While ready, subscription confirmations activate pending interest and ticker
/// updates refresh cached prices only for confirmed subscriptions. Responses that
/// do not apply to the current phase or tracked interest are ignored.
fn receive_message(state: State, message: KrakenResponse) -> State {
  case message, state.phase {
    Pong(req_id), _ -> {
      case state.timers.pong {
        Some(#(expected, timer)) if req_id == expected -> {
          let _ = process.cancel_timer(timer)
          State(..state, timers: Timers(..state.timers, pong: None))
        }
        _ -> state
      }
    }

    InstrumentsResponse(instruments), Discovering(worker, socket) -> {
      let symbols =
        instruments
        |> list.map(fn(pair) { pair.symbol })
        |> set.from_list

      pairs.set(symbols)

      connection.send(
        socket,
        KrakenRequest(request.Unsubscribe, Instruments, None),
      )

      let restore =
        state.subscriptions
        |> subscription_counter.symbols
        |> list.filter(set.contains(symbols, _))

      list.each(restore, fn(symbol) {
        connection.send(
          socket,
          KrakenRequest(request.Subscribe, Tickers([symbol]), None),
        )
      })

      cancel_timer(state.timers.discovery)

      let stable =
        schedule_event(
          state,
          state.config.stable_connection_ms,
          StabilityIntervalElapsed,
        )

      let downtime = case state.disconnected_at {
        Some(started) -> time.monotonic_time_ms() - started
        None -> 0
      }

      state.logger
      |> logger.with("generation", int.to_string(state.generation))
      |> logger.with("downtime_ms", int.to_string(downtime))
      |> logger.with("restored_symbols", int.to_string(list.length(restore)))
      |> logger.info("Kraken connection ready")

      State(
        ..state,
        phase: Ready(worker, socket),
        supported_symbols: Some(symbols),
        disconnected_at: None,
        timers: Timers(..state.timers, discovery: None, stable: Some(stable)),
      )
    }

    TickerSubscribeConfirmation(symbol), Ready(_, _) -> {
      // Obsolete/duplicate confirmations must not bring down the ETS owner.
      use <- bool.guard(
        subscription_counter.is_actively_subscribed(state.subscriptions, symbol),
        state,
      )

      case
        subscription_counter.confirm_subscription(state.subscriptions, symbol)
      {
        Ok(subscriptions) -> State(..state, subscriptions:)
        Error(_) -> state
      }
    }

    TickerResponse(symbol, price, timestamp), Ready(_, _) -> {
      case
        subscription_counter.is_actively_subscribed(state.subscriptions, symbol)
      {
        True -> price_store.insert(state.price_store, symbol, price, timestamp)
        False -> Nil
      }
      state
    }

    _, _ -> state
  }
}

/// Begins recovery after a connection failure, ignoring repeated calls while
/// stopping or waiting to reconnect. Cancels timers, logs the failure, requests
/// worker termination, and enters `Stopping` until the worker's exit is observed.
/// Preserves cached prices and the start of the current outage, and marks all
/// remaining subscription interest as pending for replay on the next connection.
/// The worker's exit notification schedules the retry.
fn disconnect(state: State, reason: String) -> State {
  case state.phase {
    Stopping(_) | WaitingToReconnect -> state

    Connecting(worker) | Discovering(worker, _) | Ready(worker, _) -> {
      cancel_all_timers(state.timers)

      state.logger
      |> logger.with("generation", int.to_string(state.generation))
      |> logger.with("reason", reason)
      |> logger.warning("Kraken connection lost")

      process.kill(worker.pid)

      let disconnected_at = case state.disconnected_at {
        None -> Some(time.monotonic_time_ms())
        some -> some
      }

      State(
        ..state,
        phase: Stopping(worker),
        timers: empty_timers(),
        disconnected_at:,
        subscriptions: subscription_counter.prepare_for_reconnect(
          state.subscriptions,
        ),
      )
    }
  }
}

/// Schedules the next connection attempt after the current retry delay plus
/// jitter, logs the delay, and enters `WaitingToReconnect`. Doubles the delay
/// for the following retry up to `retry_max_ms`; jitter is added after the cap.
/// Called once the previous worker's exit has been observed.
fn schedule_reconnect(state: State) -> State {
  let delay = state.retry_delay_ms + state.config.jitter_ms()
  let _ = schedule_event(state, delay, ReconnectDelayElapsed)

  state.logger
  |> logger.with("generation", int.to_string(state.generation))
  |> logger.with("delay_ms", int.to_string(delay))
  |> logger.warning("Retrying Kraken connection")

  State(
    ..state,
    phase: WaitingToReconnect,
    retry_delay_ms: int.min(state.retry_delay_ms * 2, state.config.retry_max_ms),
  )
}

/// Enqueues an event after `delay_ms` milliseconds, tagged with the current
/// connection attempt number. Events from an earlier attempt are ignored by
/// `handle_message`, even if already queued when their timer is cancelled.
/// Returns the timer handle so the caller can cancel it when needed.
fn schedule_event(state: State, delay_ms: Int, event: Event) -> Timer {
  process.send_after(
    state.self,
    delay_ms,
    GenerationEvent(state.generation, event),
  )
}

fn empty_timers() -> Timers {
  Timers(None, None, None, None)
}

fn cancel_timer(timer: Option(Timer)) -> Nil {
  case timer {
    Some(timer) -> {
      let _ = process.cancel_timer(timer)
      Nil
    }
    None -> Nil
  }
}

fn cancel_all_timers(timers: Timers) -> Nil {
  [timers.ping, timers.discovery, timers.stable]
  |> list.each(cancel_timer)

  case timers.pong {
    Some(#(_, timer)) -> cancel_timer(Some(timer))
    None -> Nil
  }
}
