import server/utils/retry

pub fn with_retry_returns_value_when_operation_succeeds_test() {
  assert Ok(1) == retry.with_retry(fn() { Ok(1) }, 1, 1)
}

pub fn with_retry_returns_error_when_operation_fails_test() {
  assert Error(Nil) == retry.with_retry(fn() { Error(Nil) }, 1, 1)
}
