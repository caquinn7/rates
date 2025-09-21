import server/integrations/kraken/subscription_counter

pub fn add_subscription_should_subscribe_and_add_to_pending_on_first_request_test() {
  let #(should_subscribe, counter) =
    subscription_counter.new()
    |> subscription_counter.add_subscription("a")

  assert should_subscribe
  assert 1 == subscription_counter.get_pending_count(counter, "a")
  assert 0 == subscription_counter.get_active_count(counter, "a")
}

pub fn add_subscription_should_not_subscribe_and_should_should_increment_pending_when_symbol_pending_test() {
  let #(_, counter) =
    subscription_counter.new()
    |> subscription_counter.add_subscription("a")

  let #(should_subscribe, counter) =
    counter
    |> subscription_counter.add_subscription("a")

  assert !should_subscribe
  assert 2 == subscription_counter.get_pending_count(counter, "a")
  assert 0 == subscription_counter.get_active_count(counter, "a")
}

pub fn add_subscription_should_not_subscribe_and_should_increment_active_symbol_active_test() {
  let #(_, counter) =
    subscription_counter.new()
    |> subscription_counter.add_subscription("a")

  let assert Ok(counter) =
    counter
    |> subscription_counter.confirm_subscription("a")

  let #(should_subscribe, counter) =
    counter
    |> subscription_counter.add_subscription("a")

  assert !should_subscribe
  assert 0 == subscription_counter.get_pending_count(counter, "a")
  assert 2 == subscription_counter.get_active_count(counter, "a")
}

pub fn confirm_subscription_moves_symbol_from_pending_to_active_test() {
  let #(_, counter) =
    subscription_counter.new()
    |> subscription_counter.add_subscription("a")

  let assert Ok(counter) =
    counter
    |> subscription_counter.confirm_subscription("a")

  assert 0 == subscription_counter.get_pending_count(counter, "a")
  assert 1 == subscription_counter.get_active_count(counter, "a")
}

pub fn confirm_subscription_returns_error_when_symbol_is_not_pending_test() {
  let result =
    subscription_counter.new()
    |> subscription_counter.confirm_subscription("a")

  assert Error(Nil) == result
}

pub fn remove_subscription_should_not_unsubscribe_when_symbol_not_tracked_test() {
  let #(should_unsubscribe, counter) =
    subscription_counter.new()
    |> subscription_counter.remove_subscription("a")

  assert !should_unsubscribe
  assert 0 == subscription_counter.get_pending_count(counter, "a")
  assert 0 == subscription_counter.get_active_count(counter, "a")
}

pub fn remove_subscription_should_unsubscribe_when_removing_last_pending_test() {
  let #(_, counter) =
    subscription_counter.new()
    |> subscription_counter.add_subscription("a")

  let #(should_unsubscribe, counter) =
    counter
    |> subscription_counter.remove_subscription("a")

  assert should_unsubscribe
  assert 0 == subscription_counter.get_pending_count(counter, "a")
  assert 0 == subscription_counter.get_active_count(counter, "a")
}

pub fn remove_subscription_should_not_unsubscribe_when_multiple_pending_test() {
  let #(_, counter) =
    subscription_counter.new()
    |> subscription_counter.add_subscription("a")

  let #(_, counter) =
    counter
    |> subscription_counter.add_subscription("a")

  let #(should_unsubscribe, counter) =
    counter
    |> subscription_counter.remove_subscription("a")

  assert !should_unsubscribe
  assert 1 == subscription_counter.get_pending_count(counter, "a")
  assert 0 == subscription_counter.get_active_count(counter, "a")
}

pub fn remove_subscription_should_unsubscribe_when_removing_last_active_with_no_pending_test() {
  let #(_, counter) =
    subscription_counter.new()
    |> subscription_counter.add_subscription("a")

  let assert Ok(counter) =
    counter
    |> subscription_counter.confirm_subscription("a")

  let #(should_unsubscribe, counter) =
    counter
    |> subscription_counter.remove_subscription("a")

  assert should_unsubscribe
  assert 0 == subscription_counter.get_pending_count(counter, "a")
  assert 0 == subscription_counter.get_active_count(counter, "a")
}

pub fn remove_subscription_should_not_unsubscribe_when_multiple_active_test() {
  let #(_, counter) =
    subscription_counter.new()
    |> subscription_counter.add_subscription("a")

  let assert Ok(counter) =
    counter
    |> subscription_counter.confirm_subscription("a")

  let #(_, counter) =
    counter
    |> subscription_counter.add_subscription("a")

  let #(should_unsubscribe, counter) =
    counter
    |> subscription_counter.remove_subscription("a")

  assert !should_unsubscribe
  assert 0 == subscription_counter.get_pending_count(counter, "a")
  assert 1 == subscription_counter.get_active_count(counter, "a")
}

pub fn is_actively_subscribed_returns_true_when_symbol_is_active_test() {
  let #(_, counter) =
    subscription_counter.new()
    |> subscription_counter.add_subscription("a")

  let assert Ok(counter) =
    counter
    |> subscription_counter.confirm_subscription("a")

  let #(_, counter) =
    counter
    |> subscription_counter.add_subscription("b")

  assert subscription_counter.is_actively_subscribed(counter, "a")
  assert !subscription_counter.is_actively_subscribed(counter, "b")
  assert !subscription_counter.is_actively_subscribed(counter, "c")
}
