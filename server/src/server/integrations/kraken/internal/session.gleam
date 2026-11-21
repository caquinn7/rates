//// Maintains a Kraken session across WebSocket connections. Only connection
//// workers are replaced on failure; the session retains the protected ETS table
//// and client reference counts.

import gleam/bool
import gleam/dict.{type Dict}
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
  Instruments, KrakenRequest, Tickers,
}
import server/integrations/kraken/internal/response.{
  type InstrumentPair, type KrakenResponse, InstrumentSnapshot, InstrumentUpdate,
  TickerResponse, TickerSubscribeConfirmation,
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
    /// Maximum silence after the handshake or the most recent inbound text
    /// message. A missed deadline closes the socket and triggers reconnection.
    inactivity_timeout_ms: Int,
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
/// Uses a handshake timeout of 5 seconds and 10-second deadlines for inbound
/// inactivity and the instrument snapshot. Reconnect delays double
/// from 5 to 60 seconds, plus 0–1000 ms of random jitter. The retry delay resets
/// after the connection remains ready for 60 seconds.
pub fn default_config() -> Config {
  Config(
    connect_timeout_ms: 5000,
    inactivity_timeout_ms: 10_000,
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
  /// The first interest is subscribed upstream once the symbol is eligible
  /// and the session is ready.
  Subscribe(String)

  /// Removes one client's interest in a symbol. Sends an upstream unsubscribe
  /// when the last reference to a requested ticker is removed.
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
/// Subscription interest and eligible cached prices survive phase transitions.
type Phase {
  /// Waiting for the worker to establish a WebSocket connection.
  /// A successful handshake starts instrument discovery.
  Connecting(Worker)

  /// The handshake has completed and the instrument snapshot is pending.
  /// Ticker subscriptions are sent after discovery establishes supported pairs.
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

/// Startup dependencies reused across connection attempts.
type Context {
  Context(logger: Logger, url: String, config: Config)
}

type State {
  State(
    /// Receives client commands, connection notifications, and timer events.
    self: Subject(Message),
    /// Handle to the session-owned ETS table, reused across reconnects.
    price_store: PriceStore,
    /// Current connection phase, including any worker and socket handles.
    phase: Phase,
    /// Zero-based connection attempt number used to discard stale events.
    generation: Int,
    /// Eligible symbols from the latest instrument data, kept across reconnects.
    /// `None` until the first instrument snapshot.
    supported_symbols: Option(Set(String)),
    /// Client interest counts by symbol. Confirmed interest returns to pending
    /// when the connection drops.
    subscriptions: SubscriptionCounter,
    /// IDs of outstanding ticker subscribe requests, keyed by symbol.
    /// Used to match acknowledgments to the current request.
    pending_ticker_requests: Dict(String, Int),
    /// Snapshot deadline during discovery or backoff reset timer while ready.
    phase_timer: Option(Timer),
    /// Delay before the next reconnect attempt, in milliseconds before jitter.
    retry_delay_ms: Int,
    /// ID for the next ticker subscribe request. The sequence spans reconnects.
    next_request_id: Int,
    /// Monotonic timestamp in milliseconds when the current outage began.
    /// Cleared when the connection becomes ready.
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
/// cached prices for pairs still listed, with their original timestamps.
pub fn start(
  logger: Logger,
  create_store: fn() -> PriceStore,
  url: String,
  config: Config,
) -> actor.StartResult(Subject(Message)) {
  let context = Context(logger:, url:, config:)

  actor.new_with_initialiser(config.connect_timeout_ms + 1000, fn(self) {
    let worker = start_worker(context, self, 0)

    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(WorkerDown)

    // Preserve the constructor's handshake/error contract and ETS ownership.
    use socket <- result.try(await_initial_connection(selector, config))

    let state =
      State(
        self:,
        price_store: create_store(),
        phase: Connecting(worker),
        generation: 0,
        supported_symbols: None,
        subscriptions: subscription_counter.new(),
        pending_ticker_requests: dict.new(),
        phase_timer: None,
        retry_delay_ms: config.retry_base_ms,
        next_request_id: 0,
        disconnected_at: None,
      )

    state
    |> begin_discovery(config, worker, socket)
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    actor.continue(handle_message(context, state, message))
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

/// Handles subscription commands, worker exits, and connection or timer events.
/// Updates client interest across reconnects and schedules recovery when the
/// current worker exits. Ignores unrelated worker notifications and events from
/// a different connection attempt before dispatching accepted events to `handle_event`.
fn handle_message(context: Context, state: State, message: Message) -> State {
  case message {
    Subscribe(symbol) -> add_interest(state, symbol)

    Unsubscribe(symbol) -> {
      let #(send_unsubscribe, subscriptions) =
        subscription_counter.remove_subscription(state.subscriptions, symbol)

      let state = case state.phase, send_unsubscribe {
        Ready(_, socket), True -> unsubscribe_ticker(state, socket, symbol)
        _, _ -> state
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
          let state = disconnect(state, context.logger, string.inspect(reason))
          schedule_reconnect(context, state)
        }

        _ -> state
      }
    }

    WorkerDown(_) -> state

    GenerationEvent(generation, event) -> {
      use <- bool.guard(generation != state.generation, state)
      handle_event(context, state, event)
    }
  }
}

/// Handles connection notifications and timers for the current connection attempt.
/// Called after `handle_message` checks the attempt number. Applies events only
/// in the relevant phase, processing Kraken responses, enforcing the discovery
/// deadline, resetting retry backoff, or starting the next connection attempt.
fn handle_event(context: Context, state: State, event: Event) -> State {
  case event, state.phase {
    ConnectionEvent(event), phase -> {
      case event, phase {
        connection.Connected(socket), Connecting(worker) ->
          begin_discovery(state, context.config, worker, socket)

        connection.Failed(reason), Connecting(_)
        | connection.Failed(reason), Discovering(_, _)
        | connection.Failed(reason), Ready(_, _)
        -> disconnect(state, context.logger, reason)

        connection.Received(message), Discovering(_, _)
        | connection.Received(message), Ready(_, _)
        -> receive_message(context, state, message)

        _, _ -> state
      }
    }

    DiscoveryDeadlineReached, Discovering(_, _) ->
      disconnect(
        state,
        context.logger,
        "Kraken instrument snapshot deadline exceeded",
      )

    StabilityIntervalElapsed, Ready(_, _) ->
      State(
        ..state,
        retry_delay_ms: context.config.retry_base_ms,
        phase_timer: None,
      )

    ReconnectDelayElapsed, WaitingToReconnect -> {
      let generation = state.generation + 1
      let worker = start_worker(context, state.self, generation)

      State(..state, generation:, phase: Connecting(worker))
    }

    _, _ -> state
  }
}

fn receive_message(
  context: Context,
  state: State,
  message: KrakenResponse,
) -> State {
  case message, state.phase {
    InstrumentSnapshot(instruments), Discovering(worker, socket) -> {
      let symbols = list.fold(instruments, set.new(), apply_instrument)
      finish_discovery(
        context,
        replace_pairs(state, symbols),
        worker,
        socket,
        symbols,
      )
    }

    InstrumentSnapshot(instruments), Ready(_, _) ->
      replace_pairs(state, list.fold(instruments, set.new(), apply_instrument))

    InstrumentUpdate(instruments), Ready(_, _) -> {
      let current = option.unwrap(state.supported_symbols, set.new())
      replace_pairs(state, list.fold(instruments, current, apply_instrument))
    }

    TickerSubscribeConfirmation(symbol, req_id), Ready(_, _) -> {
      // A delisted and relisted ticker can receive an old ack on this socket.
      use <- bool.guard(
        dict.get(state.pending_ticker_requests, symbol) != Ok(req_id),
        state,
      )

      case
        subscription_counter.confirm_subscription(state.subscriptions, symbol)
      {
        Ok(subscriptions) ->
          State(
            ..state,
            subscriptions:,
            pending_ticker_requests: dict.delete(
              state.pending_ticker_requests,
              symbol,
            ),
          )
        Error(_) -> state
      }
    }

    TickerResponse(symbol, price, timestamp), Ready(_, _) -> {
      case
        supports(state, symbol)
        && subscription_counter.is_actively_subscribed(
          state.subscriptions,
          symbol,
        )
      {
        True -> price_store.insert(state.price_store, symbol, price, timestamp)
        False -> Nil
      }
      state
    }

    _, _ -> state
  }
}

/// Starts a connection worker owned by this session and monitors its process.
/// Forwards connection notifications to the session, tagging each with the given
/// connection attempt number so events from older attempts can be ignored.
/// Returns the worker PID and monitor used to detect its exit and begin recovery.
fn start_worker(
  context: Context,
  self: Subject(Message),
  generation: Int,
) -> Worker {
  let pid =
    connection.start(
      process.self(),
      fn(event) {
        process.send(self, GenerationEvent(generation, ConnectionEvent(event)))
      },
      context.logger,
      context.url,
      context.config.connect_timeout_ms,
      context.config.inactivity_timeout_ms,
      context.config.send_text,
    )
  Worker(pid, process.monitor(pid))
}

/// Begins instrument discovery after a successful WebSocket handshake.
/// Requests the instrument snapshot, schedules its deadline, and enters
/// `Discovering` with the worker and socket.
/// Keeps the instrument subscription open for updates after the first snapshot.
fn begin_discovery(
  state: State,
  config: Config,
  worker: Worker,
  socket: connection.Socket,
) -> State {
  connection.send(socket, KrakenRequest(request.Subscribe, Instruments, None))

  let discovery =
    schedule_event(state, config.discovery_timeout_ms, DiscoveryDeadlineReached)

  State(
    ..state,
    phase: Discovering(worker, socket),
    phase_timer: Some(discovery),
  )
}

/// Marks the connection ready after its first instrument snapshot is applied.
/// Requests tickers for supported pairs with client interest, cancels the
/// snapshot deadline, and starts the stability timer for resetting retry backoff.
fn finish_discovery(
  context: Context,
  state: State,
  worker: Worker,
  socket: connection.Socket,
  symbols: Set(String),
) -> State {
  let restore =
    state.subscriptions
    |> subscription_counter.symbols
    |> list.filter(set.contains(symbols, _))
  let state =
    list.fold(restore, state, fn(state, symbol) {
      subscribe_ticker(state, socket, symbol)
    })

  cancel_timer(state.phase_timer)

  let stable =
    schedule_event(
      state,
      context.config.stable_connection_ms,
      StabilityIntervalElapsed,
    )

  let downtime = case state.disconnected_at {
    Some(started) -> time.monotonic_time_ms() - started
    None -> 0
  }

  context.logger
  |> logger.with("generation", int.to_string(state.generation))
  |> logger.with("downtime_ms", int.to_string(downtime))
  |> logger.with("restored_symbols", int.to_string(list.length(restore)))
  |> logger.info("Kraken connection ready")

  State(
    ..state,
    phase: Ready(worker, socket),
    disconnected_at: None,
    phase_timer: Some(stable),
  )
}

/// Begins recovery after a connection failure, ignoring repeated calls while
/// stopping or waiting to reconnect. Cancels the phase timer, logs the failure,
/// requests worker termination, and enters `Stopping` until the worker exits.
/// Preserves cached prices and the start of the current outage, and marks all
/// remaining subscription interest as pending for replay on the next connection.
/// The worker's exit notification schedules the retry.
fn disconnect(state: State, logger: Logger, reason: String) -> State {
  case state.phase {
    Stopping(_) | WaitingToReconnect -> state

    Connecting(worker) | Discovering(worker, _) | Ready(worker, _) -> {
      cancel_timer(state.phase_timer)

      logger
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
        phase_timer: None,
        disconnected_at:,
        pending_ticker_requests: dict.new(),
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
fn schedule_reconnect(context: Context, state: State) -> State {
  let delay = state.retry_delay_ms + context.config.jitter_ms()
  let _ = schedule_event(state, delay, ReconnectDelayElapsed)

  context.logger
  |> logger.with("generation", int.to_string(state.generation))
  |> logger.with("delay_ms", int.to_string(delay))
  |> logger.warning("Retrying Kraken connection")

  State(
    ..state,
    phase: WaitingToReconnect,
    retry_delay_ms: int.min(
      state.retry_delay_ms * 2,
      context.config.retry_max_ms,
    ),
  )
}

/// Publishes the first pair registry and subsequent membership changes.
/// Evicts cached prices for removed pairs before publishing the new set.
/// While ready, stops tickers for removed pairs and requests tickers for newly
/// supported pairs with pending client interest. Interest survives pair removal.
fn replace_pairs(state: State, symbols: Set(String)) -> State {
  // Metadata-only updates need no persistent_term write.
  use <- bool.guard(state.supported_symbols == Some(symbols), state)

  let previous = option.unwrap(state.supported_symbols, set.new())
  let removed = set.difference(previous, symbols)
  let state =
    set.fold(removed, state, fn(state, symbol) {
      // Evict cached prices before publishing the new registry to readers.
      price_store.delete_price(state.price_store, symbol)

      case state.phase {
        Ready(_, socket) -> {
          let state = unsubscribe_ticker(state, socket, symbol)
          State(
            ..state,
            subscriptions: subscription_counter.suspend(
              state.subscriptions,
              symbol,
            ),
          )
        }
        _ -> state
      }
    })

  pairs.set(symbols)
  let state = State(..state, supported_symbols: Some(symbols))

  case state.phase {
    Ready(_, socket) ->
      set.fold(set.difference(symbols, previous), state, fn(state, symbol) {
        case
          subscription_counter.get_pending_count(state.subscriptions, symbol)
        {
          0 -> state
          _ -> subscribe_ticker(state, socket, symbol)
        }
      })
    _ -> state
  }
}

/// Applies one pair from a snapshot or update to the set of supported symbols.
/// Removes the pair for `delisted` and includes it for every other status.
fn apply_instrument(symbols: Set(String), pair: InstrumentPair) -> Set(String) {
  case pair.status {
    "delisted" -> set.delete(symbols, pair.symbol)
    _ -> set.insert(symbols, pair.symbol)
  }
}

/// Checks whether a symbol belongs to the latest known pair registry.
/// Returns `False` before the first snapshot.
fn supports(state: State, symbol: String) -> Bool {
  case state.supported_symbols {
    Some(symbols) -> set.contains(symbols, symbol)
    None -> False
  }
}

/// Counts a subscriber's interest even if the pair was delisted between lookup
/// and `Subscribe`, so its matching `Unsubscribe` removes that same interest.
fn add_interest(state: State, symbol: String) -> State {
  let #(first_interest, subscriptions) =
    subscription_counter.add_subscription(state.subscriptions, symbol)
  let state = State(..state, subscriptions:)

  case state.phase {
    Ready(_, socket) if first_interest ->
      case supports(state, symbol) {
        True -> subscribe_ticker(state, socket, symbol)
        False -> state
      }
    _ -> state
  }
}

fn subscribe_ticker(
  state: State,
  socket: connection.Socket,
  symbol: String,
) -> State {
  let req_id = state.next_request_id
  connection.send(
    socket,
    KrakenRequest(request.Subscribe, Tickers([symbol]), Some(req_id)),
  )
  State(
    ..state,
    next_request_id: req_id + 1,
    pending_ticker_requests: dict.insert(
      state.pending_ticker_requests,
      symbol,
      req_id,
    ),
  )
}

fn unsubscribe_ticker(
  state: State,
  socket: connection.Socket,
  symbol: String,
) -> State {
  let requested =
    dict.has_key(state.pending_ticker_requests, symbol)
    || subscription_counter.is_actively_subscribed(state.subscriptions, symbol)
  use <- bool.guard(!requested, state)

  connection.send(
    socket,
    KrakenRequest(request.Unsubscribe, Tickers([symbol]), None),
  )
  State(
    ..state,
    pending_ticker_requests: dict.delete(state.pending_ticker_requests, symbol),
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

fn cancel_timer(timer: Option(Timer)) -> Nil {
  case timer {
    Some(timer) -> {
      let _ = process.cancel_timer(timer)
      Nil
    }
    None -> Nil
  }
}
