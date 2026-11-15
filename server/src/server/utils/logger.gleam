//// Structured logging with immutable context fields.
////
//// Each logging call sets `"pid"` to the emitting process's PID, overriding any
//// supplied value. The PID is captured at log time, so a logger can be shared
//// across processes.

import gleam/erlang/process
import gleam/string
import glight

/// Immutable structured fields attached to log messages.
pub opaque type Logger {
  Logger(glight.LoggerContext)
}

/// Creates an empty logging context.
pub fn new() -> Logger {
  Logger(glight.logger())
}

/// Returns a new logger with the field added or its previous value replaced.
/// The original logger is unchanged.
pub fn with(logger: Logger, key: String, value: String) -> Logger {
  let Logger(context) = logger
  Logger(glight.with(context, key, value))
}

/// Returns a new logger with the `"source"` field set or replaced.
pub fn with_source(logger: Logger, source: String) -> Logger {
  with(logger, "source", source)
}

pub fn debug(logger: Logger, message: String) -> Nil {
  glight.debug(context_for_log(logger), message)
  Nil
}

/// Builds and logs a debug event only when the primary log level permits it.
/// The builder runs synchronously, once, in the emitting process. Keep field
/// construction and message formatting inside it to defer that work.
///
/// Later filters may still discard the event. Erlang reports builder failures
/// as diagnostic log events instead of propagating the exception.
pub fn debug_lazy(build: fn() -> #(Logger, String)) -> Nil {
  log_lazy(glight.Debug, fn(_) {
    let #(logger, message) = build()

    logger
    |> context_for_log
    |> glight.with("msg", message)
  })
}

pub fn info(logger: Logger, message: String) -> Nil {
  glight.info(context_for_log(logger), message)
  Nil
}

pub fn warning(logger: Logger, message: String) -> Nil {
  glight.warning(context_for_log(logger), message)
  Nil
}

pub fn error(logger: Logger, message: String) -> Nil {
  glight.error(context_for_log(logger), message)
  Nil
}

fn context_for_log(logger: Logger) -> glight.LoggerContext {
  let Logger(context) = logger
  glight.with(context, "pid", string.inspect(process.self()))
}

fn log_lazy(
  level: glight.LogLevel,
  build_report: fn(Nil) -> glight.LoggerContext,
) -> Nil {
  erlang_log_lazy(level, build_report, Nil)
  Nil
}

@external(erlang, "logger", "log")
fn erlang_log_lazy(
  level: glight.LogLevel,
  build_report: fn(Nil) -> glight.LoggerContext,
  argument: Nil,
) -> Nil
