import server/utils/retry

pub fn attempt_returns_value_when_operation_succeeds_test() {
  assert retry.attempt(fn() { Ok(1) }, 1, 1) == Ok(1)
}

pub fn attempt_returns_error_when_operation_fails_test() {
  assert retry.attempt(fn() { Error(Nil) }, 1, 1) == Error(Nil)
}
