import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/string
import glight

pub opaque type Logger {
  Logger(Dict(String, String))
}

fn unwrap(logger) {
  let Logger(unwrapped) = logger
  unwrapped
}

// builder functions

pub fn new() -> Logger {
  glight.logger()
  |> Logger
}

pub fn with(logger: Logger, key: String, value: String) -> Logger {
  logger
  |> unwrap
  |> glight.with(key, value)
  |> Logger
}

pub fn with_pid(logger: Logger) -> Logger {
  logger
  |> with("pid", string.inspect(process.self()))
}

pub fn with_source(logger: Logger, source: String) -> Logger {
  logger
  |> with("source", source)
}

// logging functions

pub fn debug(logger: Logger, message: String) -> Nil {
  logger
  |> unwrap
  |> glight.debug(message)
  Nil
}

pub fn info(logger: Logger, message: String) -> Nil {
  logger
  |> unwrap
  |> glight.info(message)
  Nil
}

pub fn warning(logger: Logger, message: String) -> Nil {
  logger
  |> unwrap
  |> glight.warning(message)
  Nil
}

pub fn error(logger: Logger, message: String) -> Nil {
  logger
  |> unwrap
  |> glight.error(message)
  Nil
}
