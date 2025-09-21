import gleam/set
import server/integrations/kraken/pairs

pub fn set_supported_pairs_test() {
  pairs.clear()
  assert Nil == pairs.set(set.from_list(["a"]))
}

pub fn set_supported_pairs_overwrites_previous_pairs_test() {
  pairs.clear()

  set.from_list(["a"])
  |> pairs.set

  set.from_list(["b"])
  |> pairs.set

  assert !pairs.exists("a")
}

pub fn exists_returns_false_when_no_symbols_have_been_set() {
  pairs.clear()
  assert !pairs.exists("a")
}

pub fn exists_returns_true_when_symbol_found_test() {
  pairs.clear()

  set.from_list(["a"])
  |> pairs.set

  assert pairs.exists("a")
}

pub fn exists_returns_false_when_symbol_not_found_test() {
  pairs.clear()
  assert !pairs.exists("a")
}

pub fn count_returns_zero_when_no_symbols_have_been_set() {
  pairs.clear()
  assert 0 == pairs.count()
}

pub fn count_returns_number_of_symbols_test() {
  pairs.clear()

  set.from_list(["a", "b"])
  |> pairs.set

  assert 2 == pairs.count()
}
