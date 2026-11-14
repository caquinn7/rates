//// Deadline-bounded request/reply channels for the currency cache.
////
//// Each call uses a short-lived process that owns its reply subject and timeout.
//// Callers wait for its final result; late replies go to the exited process.

import gleam/erlang/process.{type Down, type Pid, type Subject}
import gleam/int
import gleam/result
import gleam/string
import server/utils/time

/// A reply destination valid only for the duration of its owning call.
pub opaque type Reply(a) {
  Reply(subject: Subject(a))
}

/// Events received by the caller while waiting for its reply process.
type CallEvent(a) {
  /// The reply process sent its final result: a reply, timeout, or target exit.
  Completed(Result(a, Nil))

  /// A monitor reported that the reply process exited. A result may already be
  /// queued, so the caller checks for it before treating this as a failure.
  WorkerExited(Down)
}

/// Monitors `pid`, sends a request, and waits until the monotonic deadline.
///
/// `send_request` runs in the reply process and must send without waiting.
/// Timeout and target termination return `Error(Nil)`. An unexpected reply-process
/// failure panics in the caller after its monitor has been removed.
pub fn call(
  pid: Pid,
  deadline_ms: Int,
  send_request: fn(Reply(a)) -> Nil,
) -> Result(a, Nil) {
  case remaining_ms(deadline_ms) {
    0 -> Error(Nil)
    _ -> {
      let caller = process.self()
      let results = process.new_subject()
      let worker =
        process.spawn_unlinked(fn() {
          wait_for_reply(pid, caller, deadline_ms, send_request, results)
        })
      let monitor = process.monitor(worker)
      let outcome =
        process.new_selector()
        |> process.select_map(results, Completed)
        |> process.select_specific_monitor(monitor, WorkerExited)
        |> process.selector_receive_forever
      process.demonitor_process(monitor)

      case outcome {
        Completed(value) -> value
        WorkerExited(down) ->
          // A fast worker may have sent its result and exited before the caller
          // began monitoring it. Consume that result before reporting a failure.
          case process.receive(results, 0) {
            Ok(value) -> value
            Error(_) ->
              panic as {
                "Cache reply process exited without a result: "
                <> string.inspect(down)
              }
          }
      }
    }
  }
}

fn wait_for_reply(
  pid: Pid,
  caller: Pid,
  deadline_ms: Int,
  send_request: fn(Reply(a)) -> Nil,
  results: Subject(Result(a, Nil)),
) -> Nil {
  let value = case remaining_ms(deadline_ms) {
    0 -> Error(Nil)
    _ -> {
      let replies = process.new_subject()
      let target_monitor = process.monitor(pid)
      let caller_monitor = process.monitor(caller)
      send_request(Reply(replies))

      let value = case remaining_ms(deadline_ms) {
        0 -> Error(Nil)
        timeout_ms ->
          process.new_selector()
          |> process.select_map(replies, Ok)
          |> process.select_specific_monitor(target_monitor, fn(_) {
            Error(Nil)
          })
          |> process.select_specific_monitor(caller_monitor, fn(_) {
            Error(Nil)
          })
          |> process.selector_receive(timeout_ms)
          |> result.flatten
      }

      process.demonitor_process(target_monitor)
      process.demonitor_process(caller_monitor)
      value
    }
  }

  // If send_request crashes, process termination releases the monitors and
  // discards its mailbox. The caller observes that failure through its monitor.
  process.send(results, value)
}

/// Sends a reply, discarding it if the receiving call has already ended.
pub fn reply(channel: Reply(a), value: a) -> Nil {
  process.send(channel.subject, value)
}

fn remaining_ms(deadline_ms: Int) -> Int {
  int.max(0, deadline_ms - time.monotonic_time_ms())
}
