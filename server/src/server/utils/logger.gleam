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
