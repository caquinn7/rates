//// Structured logging with immutable context fields and an optional event sink.
////
//// Each emitted event sets `"pid"` to the emitting process's PID, overriding any
//// supplied value. The PID is captured at log time, so a logger can be shared
//// across processes.

import gleam/dict.{type Dict}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/order.{type Order, Lt}
import gleam/string
import glight

/// A structured event delivered to an injected sink.
/// The explicit message is separate from the fields, which include the emitting PID.
pub type LogEntry {
  LogEntry(
    level: glight.LogLevel,
    message: String,
    fields: Dict(String, String),
  )
}

/// Immutable logging context and its destination.
pub opaque type Logger {
  Logger(context: glight.LoggerContext, backend: Backend)
}

type Backend {
  Erlang
  Sink(minimum_level: glight.LogLevel, emit: fn(LogEntry) -> Nil)
}

/// Creates an empty logging context that uses Erlang's logger.
pub fn new() -> Logger {
  Logger(glight.logger(), Erlang)
}

/// Creates an empty logging context that delivers events at or above the minimum
/// level to the supplied sink. The sink runs synchronously in the emitting process.
pub fn new_with_sink(
  minimum_level: glight.LogLevel,
  emit: fn(LogEntry) -> Nil,
) -> Logger {
  Logger(glight.logger(), Sink(minimum_level, emit))
}

/// Returns a new logger with the field added or its previous value replaced.
/// The original logger is unchanged.
pub fn with(logger: Logger, key: String, value: String) -> Logger {
  Logger(..logger, context: glight.with(logger.context, key, value))
}

/// Returns a new logger with the `"source"` field set or replaced.
pub fn with_source(logger: Logger, source: String) -> Logger {
  with(logger, "source", source)
}

pub fn debug(logger: Logger, message: String) -> Nil {
  log(logger, glight.Debug, message)
}

/// Builds and logs a debug event only when the given logger permits it. The
/// builder supplies the fields and message and runs once in the emitting process.
/// Keep field construction and message formatting inside it to defer that work.
///
/// With the Erlang backend, later filters may still discard the event. Erlang
/// reports builder failures as diagnostic log events.
pub fn debug_lazy(logger: Logger, build: fn() -> #(Logger, String)) -> Nil {
  case logger.backend {
    Erlang ->
      erlang_log_lazy(glight.Debug, fn(_) {
        let #(context, message) = build()
        report(context, message)
      })

    Sink(glight.Debug, emit) -> {
      let #(context, message) = build()
      emit_entry(emit, glight.Debug, context, message)
    }

    // The sink's minimum level is above Debug, so skip the builder.
    Sink(_, _) -> Nil
  }
}

pub fn info(logger: Logger, message: String) -> Nil {
  log(logger, glight.Info, message)
}

pub fn warning(logger: Logger, message: String) -> Nil {
  log(logger, glight.Warning, message)
}

pub fn error(logger: Logger, message: String) -> Nil {
  log(logger, glight.Error, message)
}

fn log(logger: Logger, level: glight.LogLevel, message: String) -> Nil {
  case logger.backend {
    Erlang -> erlang_log(level, report(logger, message))

    Sink(minimum_level, emit) ->
      case compare_levels(level, minimum_level) {
        Lt -> Nil
        _ -> emit_entry(emit, level, logger, message)
      }
  }
}

fn context_for_log(logger: Logger) -> glight.LoggerContext {
  glight.with(logger.context, "pid", string.inspect(process.self()))
}

fn report(logger: Logger, message: String) -> glight.LoggerContext {
  logger
  |> context_for_log
  |> glight.with("msg", message)
}

fn emit_entry(
  emit: fn(LogEntry) -> Nil,
  level: glight.LogLevel,
  logger: Logger,
  message: String,
) -> Nil {
  let fields =
    logger
    |> context_for_log
    |> dict.delete("msg")
  emit(LogEntry(level, message, fields))
}

@external(erlang, "logger", "compare_levels")
fn compare_levels(
  level: glight.LogLevel,
  minimum_level: glight.LogLevel,
) -> Order

fn erlang_log(level: glight.LogLevel, report: glight.LoggerContext) -> Nil {
  let _ = do_erlang_log(level, report)
  Nil
}

@external(erlang, "logger", "log")
fn do_erlang_log(level: glight.LogLevel, report: glight.LoggerContext) -> Atom

fn erlang_log_lazy(
  level: glight.LogLevel,
  build_report: fn(Nil) -> glight.LoggerContext,
) -> Nil {
  let _ = do_erlang_log_lazy(level, build_report, Nil)
  Nil
}

@external(erlang, "logger", "log")
fn do_erlang_log_lazy(
  level: glight.LogLevel,
  build_report: fn(Nil) -> glight.LoggerContext,
  argument: Nil,
) -> Atom
