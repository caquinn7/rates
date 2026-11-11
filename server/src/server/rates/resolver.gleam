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

  /// A trapped exit notification from the owner or the linked worker.
  LinkedExited(process.ExitMessage)
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

/// Resolves one rate within a millisecond budget, including resolver startup.
/// Creates a controller and lookup worker internally; both stop after the lookup.
/// Nonpositive budgets return `TimedOut` without starting either process.
/// Unexpected startup failures or resolver and worker crashes still raise.
pub fn get_rate(
  config: RateServiceConfig,
  rate_request: RateRequest,
  timeout: Int,
) -> Result(RateResponse, ResolveError) {
  case timeout <= 0 {
    True -> Error(TimedOut(rate_request))
    False -> {
      let deadline_ms = time.monotonic_time_ms() + timeout
      let reply_to = process.new_subject()
      use started <- result.try(
        start(config, rate_request, reply_to, deadline_ms)
        |> result.map_error(fn(error) {
          case error, remaining_ms(deadline_ms) {
            actor.InitTimeout, 0 -> TimedOut(rate_request)
            _, _ ->
              panic as {
                "rate resolver failed to start: " <> string.inspect(error)
              }
          }
        }),
      )
      let monitor = process.monitor(started.pid)
      let selector =
        process.new_selector()
        |> process.select_map(reply_to, Answer)
        |> process.select_specific_monitor(monitor, ResolverDown)

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
          process.send(started.data, Cancel)
          Error(TimedOut(rate_request))
        }
      }
    }
  }
}

/// Starts the controller with an active lookup and its cleanup resources.
fn start(
  config: RateServiceConfig,
  request: RateRequest,
  reply_to: Subject(Reply),
  deadline_ms: Int,
) -> Result(actor.Started(Subject(Msg)), StartError) {
  actor.new_with_initialiser(int.min(1000, remaining_ms(deadline_ms)), fn(self) {
    process.trap_exits(True)
    // Linking also stops the worker if controller startup fails or it crashes.
    // The monitor supplies worker crash details and confirms cleanup completion.
    let worker =
      process.spawn(fn() {
        let result = case remaining_ms(deadline_ms) {
          0 -> Error(TimedOut(request))
          _ -> resolve(self, config, request, deadline_ms)
        }
        process.send(self, Completed(result))
      })

    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(WorkerDown)
      |> process.select_trapped_exits(LinkedExited)

    Pending(
      reply_to:,
      request:,
      deadline_ms:,
      worker:,
      monitor: process.monitor(worker),
      timer: process.send_after(
        self,
        remaining_ms(deadline_ms),
        DeadlineReached,
      ),
      interest: None,
    )
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(fn(pending, message) {
    handle_msg(pending, message, config.kraken_interface)
  })
  |> actor.start
}

fn handle_msg(
  pending: Pending,
  msg: Msg,
  kraken: KrakenInterface,
) -> Next(Pending, Msg) {
  case msg {
    AcquireKraken(symbol, acknowledge) ->
      case remaining_ms(pending.deadline_ms) {
        0 -> timed_out(pending, kraken)
        _ -> {
          kraken.subscribe(symbol)
          process.send(acknowledge, Nil)
          actor.continue(Pending(..pending, interest: Some(symbol)))
        }
      }

    ReleaseKraken -> actor.continue(release_interest(pending, kraken))

    Completed(result) ->
      case remaining_ms(pending.deadline_ms) {
        0 -> timed_out(pending, kraken)
        _ -> finish(pending, Some(Resolved(result)), kraken)
      }

    DeadlineReached -> timed_out(pending, kraken)
    Cancel -> finish(pending, None, kraken)
    LinkedExited(exit) ->
      case exit.pid == pending.worker {
        // Worker exits are handled by the monitor notification instead.
        True -> actor.continue(pending)
        False -> finish(pending, None, kraken)
      }
    WorkerDown(process.ProcessDown(reason:, ..)) ->
      finish(pending, Some(Crashed(reason)), kraken)
    WorkerDown(down) ->
      panic as {
        "expected worker process exit notification, received: "
        <> string.inspect(down)
      }
  }
}

/// Builds a `TimedOut` reply, then delegates cleanup and shutdown to `finish`.
fn timed_out(pending: Pending, kraken: KrakenInterface) -> Next(Pending, Msg) {
  finish(pending, Some(Resolved(Error(TimedOut(pending.request)))), kraken)
}

/// Finalizes both successful and failed requests, including cancellation.
fn finish(
  pending: Pending,
  reply: Option(Reply),
  kraken: KrakenInterface,
) -> Next(Pending, Msg) {
  let _ = process.cancel_timer(pending.timer)
  let pending = release_interest(pending, kraken)
  stop_worker(pending.worker, pending.monitor)
  case reply {
    Some(reply) -> process.send(pending.reply_to, reply)
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
