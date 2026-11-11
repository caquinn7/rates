//// Resolves one exchange rate within a caller-supplied deadline.
////
//// A private worker selects Kraken or CoinMarketCap and performs blocking
//// lookups. The resolver actor owns temporary Kraken interest and remains
//// responsive to cancellation while the worker runs. Every completion path
//// releases that interest and stops the worker before the resolver exits.

import gleam/erlang/process.{type Monitor, type Pid, type Subject, type Timer}
import gleam/function
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor.{type Next, type StartError}
import gleam/result
import gleam/string
import server/rates/internal/kraken_interface.{type KrakenInterface}
import server/rates/internal/kraken_symbol.{type KrakenSymbol}
import server/rates/internal/rate_source_strategy.{
  KrakenStrategy, StrategyBehavior, StrategyConfig,
}
import server/rates/rate_error.{type RateError}
import server/rates/rate_service_config.{type RateServiceConfig}
import server/utils/time
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}

/// A handle to an actor that resolves a single exchange rate.
/// Create with `new`, then call `get_rate` once with a time budget in milliseconds.
/// The actor stops after the lookup finishes or its deadline expires.
pub opaque type RateResolver {
  RateResolver(pid: Pid, subject: Subject(Msg))
}

/// Failures from resolving a rate within a caller-supplied deadline.
pub type ResolveError {
  /// A currency lookup or rate provider failed.
  LookupFailed(RateError)
  /// The resolver did not finish within its caller-supplied deadline.
  TimedOut(RateRequest)
}

/// The terminal outcome sent by the resolver actor to the `get_rate` caller.
type Reply {
  /// A successful quote, lookup failure, or deadline timeout.
  Resolved(Result(RateResponse, ResolveError))

  /// An unexpected worker exit. Carries the exit reason so `get_rate` can raise
  /// with the original crash details.
  Crashed(process.ExitReason)
}

/// Events selected while `get_rate` waits for the resolver's reply.
type CallEvent {
  /// A reply received from the resolver actor.
  Answer(Reply)

  /// A process monitor notification that the resolver actor has exited.
  ResolverDown(process.Down)
}

/// Messages and lifecycle notifications received by the resolver actor.
type Msg {
  /// A rate lookup request with a reply subject, currency pair, and absolute
  /// deadline in monotonic milliseconds.
  GetRate(Subject(Reply), RateRequest, deadline_ms: Int)

  /// A worker request to subscribe to a Kraken symbol, with an acknowledgement
  /// subject.
  AcquireKraken(KrakenSymbol, Subject(Nil))

  /// A worker request to release this lookup's Kraken subscription.
  ReleaseKraken

  /// The lookup worker's result, containing a quote or a resolution error.
  Completed(Result(RateResponse, ResolveError))

  /// A timer notification that the pending request's deadline has elapsed.
  DeadlineReached

  /// A caller request to cancel the lookup.
  Cancel

  /// A process monitor notification that the lookup worker has exited.
  WorkerDown(process.Down)

  /// A trapped exit notification from the process that started the resolver.
  OwnerExited
}

/// Request details and resources for an active rate lookup.
/// Tracks the reply destination, absolute deadline in monotonic milliseconds,
/// worker, monitor, timer, and any Kraken subscription held for the lookup.
type Pending {
  Pending(
    reply_to: Subject(Reply),
    request: RateRequest,
    deadline_ms: Int,
    worker: Pid,
    monitor: Monitor,
    timer: Timer,
    interest: Option(KrakenSymbol),
  )
}

type State {
  State(self: Subject(Msg), pending: Option(Pending))
}

/// Starts a one-shot resolver. Call `get_rate` once with the desired time budget.
pub fn new(config: RateServiceConfig) -> Result(RateResolver, StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    // Handle the owner's exit explicitly so its outstanding work is cleaned up.
    process.trap_exits(True)
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(WorkerDown)
      |> process.select_trapped_exits(fn(_) { OwnerExited })

    State(self, None)
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(fn(state, message) { handle_msg(state, message, config) })
  |> actor.start
  |> result.map(fn(started) { RateResolver(started.pid, started.data) })
}

/// Resolves a rate, returning `TimedOut` when the millisecond budget expires.
/// Nonpositive budgets time out without starting any provider work.
/// Unexpected resolver or worker crashes still raise, preserving their details.
pub fn get_rate(
  resolver: RateResolver,
  rate_request: RateRequest,
  timeout: Int,
) -> Result(RateResponse, ResolveError) {
  let RateResolver(pid:, subject:) = resolver
  let deadline_ms = time.monotonic_time_ms() + int.max(timeout, 0)

  case timeout <= 0 {
    True -> {
      process.send(subject, Cancel)
      Error(TimedOut(rate_request))
    }
    False -> {
      let reply_to = process.new_subject()
      let monitor = process.monitor(pid)
      let selector =
        process.new_selector()
        |> process.select_map(reply_to, Answer)
        |> process.select_specific_monitor(monitor, ResolverDown)

      process.send(subject, GetRate(reply_to, rate_request, deadline_ms))
      let answer = process.selector_receive(selector, remaining_ms(deadline_ms))
      process.demonitor_process(monitor)

      case answer {
        Ok(Answer(Resolved(result))) -> result
        Ok(Answer(Crashed(reason)))
        | Ok(ResolverDown(process.ProcessDown(reason:, ..))) ->
          panic as { "rate resolver exited: " <> string.inspect(reason) }
        Ok(ResolverDown(down)) ->
          panic as { "rate resolver exited: " <> string.inspect(down) }
        Error(_) -> {
          process.send(subject, Cancel)
          Error(TimedOut(rate_request))
        }
      }
    }
  }
}

fn handle_msg(
  state: State,
  msg: Msg,
  config: RateServiceConfig,
) -> Next(State, Msg) {
  case msg {
    GetRate(reply_to, request, deadline_ms) -> {
      case state.pending {
        Some(_) -> panic as "a rate resolver can only be used once"
        None ->
          case remaining_ms(deadline_ms) {
            0 -> {
              process.send(reply_to, Resolved(Error(TimedOut(request))))
              actor.stop()
            }
            remaining -> {
              let worker =
                process.spawn_unlinked(fn() {
                  let result = resolve(state.self, config, request, deadline_ms)
                  process.send(state.self, Completed(result))
                })
              let pending =
                Pending(
                  reply_to:,
                  request:,
                  deadline_ms:,
                  worker:,
                  monitor: process.monitor(worker),
                  timer: process.send_after(
                    state.self,
                    remaining,
                    DeadlineReached,
                  ),
                  interest: None,
                )
              actor.continue(State(..state, pending: Some(pending)))
            }
          }
      }
    }

    AcquireKraken(symbol, acknowledge) -> {
      case state.pending {
        Some(pending) ->
          case remaining_ms(pending.deadline_ms) {
            0 -> timed_out(state, config.kraken_interface)
            _ -> {
              config.kraken_interface.subscribe(symbol)
              process.send(acknowledge, Nil)
              actor.continue(
                State(
                  ..state,
                  pending: Some(Pending(..pending, interest: Some(symbol))),
                ),
              )
            }
          }
        None -> actor.continue(state)
      }
    }

    ReleaseKraken -> {
      let pending =
        option.map(state.pending, release_interest(_, config.kraken_interface))
      actor.continue(State(..state, pending:))
    }

    Completed(result) ->
      case state.pending {
        Some(pending) ->
          case remaining_ms(pending.deadline_ms) {
            0 -> timed_out(state, config.kraken_interface)
            _ -> finish(state, Some(Resolved(result)), config.kraken_interface)
          }
        None -> actor.continue(state)
      }

    DeadlineReached -> timed_out(state, config.kraken_interface)
    Cancel | OwnerExited -> finish(state, None, config.kraken_interface)
    WorkerDown(process.ProcessDown(reason:, ..)) ->
      finish(state, Some(Crashed(reason)), config.kraken_interface)
    WorkerDown(down) ->
      panic as {
        "expected worker process exit notification, received: "
        <> string.inspect(down)
      }
  }
}

/// Builds a `TimedOut` reply for the pending request, then delegates cleanup and
/// resolver shutdown to `finish`. With no pending request, no reply is sent.
fn timed_out(state: State, kraken: KrakenInterface) -> Next(State, Msg) {
  let reply =
    option.map(state.pending, fn(pending) {
      Resolved(Error(TimedOut(pending.request)))
    })
  finish(state, reply, kraken)
}

/// Finalizes both successful and failed requests, including cancellation.
fn finish(
  state: State,
  reply: Option(Reply),
  kraken: KrakenInterface,
) -> Next(State, Msg) {
  case state.pending {
    Some(pending) -> {
      let _ = process.cancel_timer(pending.timer)
      let pending = release_interest(pending, kraken)
      stop_worker(pending.worker, pending.monitor)
      case reply {
        Some(reply) -> process.send(pending.reply_to, reply)
        None -> Nil
      }
    }
    None -> Nil
  }
  actor.stop()
}

/// Kills the worker if it is still alive, waits for its exit notification, and
/// removes the monitor. If already dead, removes the monitor without waiting.
fn stop_worker(worker: Pid, monitor: Monitor) -> Nil {
  case process.is_alive(worker) {
    True -> {
      process.kill(worker)
      let _ =
        process.new_selector()
        |> process.select_specific_monitor(monitor, function.identity)
        |> process.selector_receive_forever
      Nil
    }
    False -> Nil
  }
  process.demonitor_process(monitor)
}

/// Unsubscribes from the lookup's recorded Kraken symbol and clears `interest`.
/// Returns the updated lookup, or the original if no subscription is recorded.
fn release_interest(pending: Pending, kraken: KrakenInterface) -> Pending {
  case pending.interest {
    Some(symbol) -> {
      kraken.unsubscribe(symbol)
      Pending(..pending, interest: None)
    }
    None -> pending
  }
}

/// Selects and executes a Kraken or CoinMarketCap strategy in the worker process.
/// Coordinates Kraken subscriptions through `controller` and wraps lookup
/// failures in `LookupFailed`.
///
/// `deadline_ms` is an absolute deadline in monotonic milliseconds. It bounds
/// the subscription acknowledgement wait; the controller enforces the overall
/// deadline, including time spent in blocking provider calls.
fn resolve(
  controller: Subject(Msg),
  config: RateServiceConfig,
  request: RateRequest,
  deadline_ms: Int,
) -> Result(RateResponse, ResolveError) {
  use strategy <- result.try(
    rate_source_strategy.determine_strategy(
      request,
      config.get_currency,
      config.kraken_interface.get_kraken_symbol,
    )
    |> result.map_error(fn(error) {
      let rate_source_strategy.CurrencyNotFound(id) = error
      LookupFailed(rate_error.CurrencyNotFound(request, id))
    }),
  )

  use _ <- result.try(case strategy {
    KrakenStrategy(symbol) -> {
      let acknowledge = process.new_subject()
      process.send(controller, AcquireKraken(symbol, acknowledge))

      process.receive(acknowledge, remaining_ms(deadline_ms))
      |> result.replace_error(TimedOut(request))
    }
    _ -> Ok(Nil)
  })

  let strategy_config =
    StrategyConfig(
      check_for_kraken_price: config.kraken_interface.check_for_price,
      request_cmc_conversion: config.request_cmc_conversion,
      behavior: StrategyBehavior(
        on_kraken_success: fn() { process.send(controller, ReleaseKraken) },
        on_kraken_failure: fn(_, _) { process.send(controller, ReleaseKraken) },
      ),
    )
  let #(result, _) =
    rate_source_strategy.execute_strategy(strategy, request, strategy_config)
  result.map_error(result, LookupFailed)
}

fn remaining_ms(deadline_ms: Int) -> Int {
  int.max(deadline_ms - time.monotonic_time_ms(), 0)
}
