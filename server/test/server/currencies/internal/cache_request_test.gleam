import exception
import gleam/erlang/process.{type Pid, type Subject}
import server/currencies/internal/cache_request.{type Reply}
import server/utils/time

pub fn call_returns_reply_and_removes_monitor_test() {
  use pid, requests <- with_server(fn(requests) {
    let assert Ok(channel) = process.receive(requests, 1000)
    cache_request.reply(channel, 42)
  })

  in_other_process(fn() {
    assert cache_request.call(pid, deadline(1000), process.send(requests, _))
      == Ok(42)
    assert monitored_processes(process.self()) == []
    assert mailbox_size(process.self()) == 0
  })
}

pub fn call_returns_error_when_server_exits_without_reply_test() {
  use pid, requests <- with_server(fn(requests) {
    let assert Ok(_) = process.receive(requests, 1000)
    Nil
  })

  in_other_process(fn() {
    // The outer test waits only one second, so a ten-second receive timeout
    // cannot mask a missing process-termination notification.
    assert cache_request.call(pid, deadline(10_000), process.send(requests, _))
      == Error(Nil)
    assert monitored_processes(process.self()) == []
    assert mailbox_size(process.self()) == 0
  })
}

pub fn call_returns_error_when_server_is_already_dead_test() {
  use pid, requests <- with_server(fn(requests) {
    let _ = process.receive_forever(requests)
    Nil
  })
  stop_process(pid)

  in_other_process(fn() {
    assert cache_request.call(pid, deadline(10_000), process.send(requests, _))
      == Error(Nil)
    assert monitored_processes(process.self()) == []
    assert mailbox_size(process.self()) == 0
  })
}

pub fn expired_call_does_not_send_request_test() {
  in_other_process(fn() {
    let send_request = fn(_) { panic as "Expired requests must not be sent" }
    assert cache_request.call(process.self(), deadline(-1), send_request)
      == Error(Nil)
    assert monitored_processes(process.self()) == []
    assert mailbox_size(process.self()) == 0
  })
}

pub fn timeout_discards_late_reply_and_allows_another_call_test() {
  let started = process.new_subject()
  let replied = process.new_subject()
  let workers = process.new_subject()
  use pid, requests <- with_server(fn(requests) {
    let assert Ok(channel) = process.receive(requests, 1000)
    let release = process.new_subject()
    process.send(started, release)
    let assert Ok(Nil) = process.receive(release, 1000)
    cache_request.reply(channel, 42)
    process.send(replied, Nil)

    let assert Ok(channel) = process.receive(requests, 1000)
    cache_request.reply(channel, 7)
  })

  let caller_ready = process.new_subject()
  let timed_out = process.new_subject()
  let finished = process.new_subject()
  let caller =
    process.spawn(fn() {
      let resume = process.new_subject()
      process.send(caller_ready, resume)
      let result =
        cache_request.call(pid, deadline(100), fn(channel) {
          process.send(workers, process.self())
          process.send(requests, channel)
        })
      process.send(timed_out, result)

      let assert Ok(Nil) = process.receive(resume, 1000)
      assert mailbox_size(process.self()) == 0
      assert monitored_processes(process.self()) == []
      assert cache_request.call(pid, deadline(1000), process.send(requests, _))
        == Ok(7)
      assert mailbox_size(process.self()) == 0
      assert monitored_processes(process.self()) == []
      process.send(finished, Nil)
    })
  use <- exception.defer(fn() { stop_process(caller) })

  let assert Ok(resume) = process.receive(caller_ready, 1000)
  let assert Ok(release) = process.receive(started, 1000)
  use <- exception.defer(fn() { process.send(release, Nil) })
  let assert Ok(worker) = process.receive(workers, 1000)
  let monitor = process.monitor(worker)
  assert process.receive(timed_out, 1000) == Ok(Error(Nil))
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)

  process.send(release, Nil)
  assert process.receive(replied, 1000) == Ok(Nil)
  process.send(resume, Nil)
  assert process.receive(finished, 1000) == Ok(Nil)
}

pub fn send_exception_propagates_after_reply_process_exits_test() {
  use pid, _ <- with_server(fn(requests) {
    let _ = process.receive_forever(requests)
    Nil
  })

  in_other_process(fn() {
    let assert Error(exception.Errored(_)) =
      exception.rescue(fn() {
        cache_request.call(pid, deadline(1000), fn(channel) {
          cache_request.reply(channel, 42)
          panic as "Failed to send request"
        })
      })
    assert mailbox_size(process.self()) == 0
    assert monitored_processes(process.self()) == []
  })
}

pub fn reply_process_exits_when_caller_dies_test() {
  use pid, requests <- with_server(fn(requests) {
    let _ = process.receive_forever(requests)
    let _ = process.receive_forever(requests)
    Nil
  })
  let started = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      let _ =
        cache_request.call(pid, deadline(10_000), fn(channel) {
          process.send(started, process.self())
          process.send(requests, channel)
        })
      Nil
    })
  use <- exception.defer(fn() { stop_process(caller) })

  let assert Ok(worker) = process.receive(started, 1000)
  let monitor = process.monitor(worker)
  stop_process(caller)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
}

fn deadline(timeout_ms: Int) -> Int {
  time.monotonic_time_ms() + timeout_ms
}

fn with_server(
  handle: fn(Subject(Reply(Int))) -> Nil,
  run: fn(Pid, Subject(Reply(Int))) -> a,
) -> a {
  let ready = process.new_subject()
  let pid =
    process.spawn(fn() {
      let requests = process.new_subject()
      process.send(ready, requests)
      handle(requests)
    })
  use <- exception.defer(fn() { stop_process(pid) })

  let assert Ok(requests) = process.receive(ready, 1000)
  run(pid, requests)
}

fn in_other_process(run: fn() -> a) -> a {
  let replies = process.new_subject()
  let pid = process.spawn(fn() { process.send(replies, run()) })
  use <- exception.defer(fn() { stop_process(pid) })

  let assert Ok(value) = process.receive(replies, 1000)
  value
}

fn stop_process(pid: Pid) -> Nil {
  process.unlink(pid)
  let monitor = process.monitor(pid)
  process.kill(pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  Nil
}

@external(erlang, "process_test_ffi", "monitored_processes")
fn monitored_processes(pid: Pid) -> List(Pid)

@external(erlang, "process_test_ffi", "mailbox_size")
fn mailbox_size(pid: Pid) -> Int
