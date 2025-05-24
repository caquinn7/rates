import gleam/set
import gleeunit/should
import server/kraken/pairs

pub fn set_supported_pairs_test() {
  pairs.clear()

  set.from_list(["a"])
  |> pairs.set
  |> should.equal(Nil)
}

pub fn set_supported_pairs_overwrites_previous_pairs_test() {
  pairs.clear()

  set.from_list(["a"])
  |> pairs.set

  set.from_list(["b"])
  |> pairs.set

  pairs.exists("a")
  |> should.be_false
}

pub fn exists_returns_false_when_no_symbols_have_been_set() {
  pairs.clear()

  pairs.exists("a")
  |> should.be_false
}

pub fn exists_returns_true_when_symbol_found_test() {
  pairs.clear()

  set.from_list(["a"])
  |> pairs.set

  pairs.exists("a")
  |> should.be_true
}

pub fn exists_returns_false_when_symbol_not_found_test() {
  pairs.clear()

  pairs.exists("a")
  |> should.be_false
}
