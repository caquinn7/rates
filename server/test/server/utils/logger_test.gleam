import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import glight
import server/utils/logger.{LogEntry}

pub fn disabled_debug_never_evaluates_builder_test() {
  [glight.Info, glight.Warning, glight.Error]
  |> list.each(fn(level) {
    use events <- with_log_capture(level)
    let calls = process.new_subject()
    let context = logger.new()

    let result =
      logger.debug_lazy(context, fn() {
        process.send(calls, Nil)
        #(context, "Disabled debug event")
      })

    assert result == Nil
    assert process.receive(calls, 0) == Error(Nil)
    assert process.receive(events, 0) == Error(Nil)
  })
}

pub fn enabled_debug_evaluates_builder_once_in_caller_process_test() {
  use events <- with_log_capture(glight.Debug)
  let calls = process.new_subject()
  let context = logger.new()

  let result =
    logger.debug_lazy(context, fn() {
      process.send(calls, process.self())
      #(context, "Enabled debug event")
    })

  assert result == Nil
  assert process.receive(calls, 0) == Ok(process.self())
  assert process.receive(calls, 0) == Error(Nil)
  let assert Ok(event) = process.receive(events, 0)
  assert dict.get(report(event), "msg") == Ok("Enabled debug event")
  assert process.receive(events, 0) == Error(Nil)
}

pub fn lazy_debug_preserves_eager_report_test() {
  use events <- with_log_capture(glight.Debug)
  let context =
    logger.new()
    |> logger.with_source("logger_test")
    |> logger.with("received", "payload")

  assert logger.debug(context, "Received websocket message") == Nil

  logger.debug_lazy(context, fn() { #(context, "Received websocket message") })

  let assert Ok(eager_event) = process.receive(events, 0)
  let assert Ok(lazy_event) = process.receive(events, 0)
  let expected =
    dict.from_list([
      #("source", "logger_test"),
      #("received", "payload"),
      #("msg", "Received websocket message"),
      #("pid", string.inspect(process.self())),
    ])

  assert report(eager_event) == expected
  assert report(lazy_event) == expected
  assert event_level(lazy_event) == "debug"
  assert process.receive(events, 0) == Error(Nil)
}

pub fn logging_overrides_supplied_msg_and_pid_test() {
  use events <- with_log_capture(glight.Debug)
  let context =
    logger.new()
    |> logger.with("msg", "supplied message")
    |> logger.with("pid", "supplied pid")

  logger.debug(context, "Explicit message")
  logger.debug_lazy(context, fn() { #(context, "Explicit message") })

  let assert Ok(eager_event) = process.receive(events, 0)
  let assert Ok(lazy_event) = process.receive(events, 0)
  let expected =
    dict.from_list([
      #("msg", "Explicit message"),
      #("pid", string.inspect(process.self())),
    ])

  assert report(eager_event) == expected
  assert report(lazy_event) == expected
  assert process.receive(events, 0) == Error(Nil)
}

pub fn lazy_debug_observes_runtime_level_changes_with_same_context_test() {
  use events <- with_log_capture(glight.Info)
  let calls = process.new_subject()
  let context = logger.new()
  let build = fn() {
    process.send(calls, Nil)
    #(context, "Runtime level event")
  }

  logger.debug_lazy(context, build)
  assert process.receive(calls, 0) == Error(Nil)
  assert process.receive(events, 0) == Error(Nil)

  glight.set_log_level(glight.Debug)
  logger.debug_lazy(context, build)
  assert process.receive(calls, 0) == Ok(Nil)
  let assert Ok(_) = process.receive(events, 0)

  glight.set_log_level(glight.Warning)
  logger.debug_lazy(context, build)
  assert process.receive(calls, 0) == Error(Nil)
  assert process.receive(events, 0) == Error(Nil)

  glight.set_log_level(glight.Debug)
  logger.debug_lazy(context, build)
  assert process.receive(calls, 0) == Ok(Nil)
  let assert Ok(_) = process.receive(events, 0)
  assert process.receive(calls, 0) == Error(Nil)
  assert process.receive(events, 0) == Error(Nil)
}

pub fn builder_failure_emits_native_diagnostic_without_propagating_test() {
  use events <- with_log_capture(glight.Debug)
  let calls = process.new_subject()

  let result =
    logger.debug_lazy(logger.new(), fn() {
      process.send(calls, Nil)
      panic as "debug builder failed"
    })

  assert result == Nil
  assert process.receive(calls, 0) == Ok(Nil)
  assert process.receive(calls, 0) == Error(Nil)
  let assert Ok(event) = process.receive(events, 0)
  assert event_level(event) == "debug"
  let diagnostic = format_message(event)
  assert string.contains(diagnostic, "LAZY_FUN CRASH")
  assert string.contains(diagnostic, "debug builder failed")
  assert process.receive(events, 0) == Error(Nil)
}

pub fn sink_filters_events_and_skips_disabled_debug_builder_test() {
  let events = process.new_subject()
  let calls = process.new_subject()
  let context = logger.new_with_sink(glight.Warning, process.send(events, _))

  logger.debug(context, "Filtered debug")
  logger.debug_lazy(context, fn() {
    process.send(calls, Nil)
    #(context, "Filtered lazy debug")
  })
  logger.info(context, "Filtered info")
  logger.warning(context, "At threshold")
  logger.error(context, "Above threshold")

  let fields = dict.from_list([#("pid", string.inspect(process.self()))])
  assert process.receive(calls, 0) == Error(Nil)
  assert process.receive(events, 0)
    == Ok(LogEntry(glight.Warning, "At threshold", fields))
  assert process.receive(events, 0)
    == Ok(LogEntry(glight.Error, "Above threshold", fields))
  assert process.receive(events, 0) == Error(Nil)
}

pub fn sink_uses_the_emitting_pid_and_preserves_structured_fields_test() {
  let events = process.new_subject()
  let calls = process.new_subject()
  let done = process.new_subject()
  let context =
    logger.new_with_sink(glight.Debug, fn(entry) {
      process.send(events, #(process.self(), entry))
    })
    |> logger.with_source("logger_test")
    |> logger.with("pid", "supplied pid")
    |> logger.with("msg", "supplied message")

  let emitter =
    process.spawn(fn() {
      logger.debug(context, "Eager message")
      logger.debug_lazy(context, fn() {
        process.send(calls, process.self())
        let built = logger.with(logger.new(), "detail", "built on demand")
        #(built, "Lazy message")
      })
      process.send(done, Nil)
    })

  let pid = string.inspect(emitter)
  let eager_fields = dict.from_list([#("source", "logger_test"), #("pid", pid)])
  let lazy_fields =
    dict.from_list([#("detail", "built on demand"), #("pid", pid)])

  assert process.receive(done, 1000) == Ok(Nil)
  assert process.receive(events, 0)
    == Ok(#(emitter, LogEntry(glight.Debug, "Eager message", eager_fields)))
  assert process.receive(events, 0)
    == Ok(#(emitter, LogEntry(glight.Debug, "Lazy message", lazy_fields)))
  assert process.receive(calls, 0) == Ok(emitter)
  assert process.receive(calls, 0) == Error(Nil)
  assert process.receive(events, 0) == Error(Nil)
}

/// Runs a test at the given primary log level, passing it a subject that receives
/// raw Erlang log events emitted by the calling process. Returns the test's result.
///
/// Removes the temporary capture handler and restores the original primary
/// configuration even if the test panics.
fn with_log_capture(
  level: glight.LogLevel,
  run: fn(Subject(Dynamic)) -> a,
) -> a {
  let events = process.new_subject()
  with_capture(level, process.send(events, _), fn() { run(events) })
}

@external(erlang, "logger_test_ffi", "with_capture")
fn with_capture(
  level: glight.LogLevel,
  emit: fn(Dynamic) -> Nil,
  run: fn() -> a,
) -> a

fn report(event: Dynamic) -> Dict(String, String) {
  let assert Ok(message) =
    decode.run(event, decode.at([atom.create("msg")], decode.dynamic))
  let assert Ok(tag) = decode.run(message, decode.at([0], atom.decoder()))
  assert atom.to_string(tag) == "report"
  let assert Ok(fields) =
    decode.run(
      message,
      decode.at([1], decode.dict(decode.string, decode.string)),
    )
  fields
}

fn event_level(event: Dynamic) -> String {
  let assert Ok(level) =
    decode.run(event, decode.at([atom.create("level")], atom.decoder()))
  atom.to_string(level)
}

@external(erlang, "logger_test_ffi", "format_message")
fn format_message(event: Dynamic) -> String
