import exception
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/set
import server/integrations/kraken/pairs

pub fn new_store_starts_empty_test() {
  let assert Ok(store) = pairs.new()
  assert pairs.count(store) == 0
  assert !pairs.exists(store, "BTC/USD")
}

pub fn membership_changes_are_local_to_one_store_test() {
  let assert Ok(first) = pairs.new()
  let assert Ok(second) = pairs.new()
  pairs.apply_changes(
    first,
    added: set.from_list(["BTC/USD", "ETH/USD"]),
    removed: set.new(),
  )
  pairs.apply_changes(
    second,
    added: set.from_list(["BTC/USD"]),
    removed: set.new(),
  )

  pairs.apply_changes(
    first,
    added: set.from_list(["XRP/USD"]),
    removed: set.from_list(["BTC/USD"]),
  )

  assert pairs.count(first) == 2
  assert pairs.exists(first, "ETH/USD")
  assert pairs.exists(first, "XRP/USD")
  assert !pairs.exists(first, "BTC/USD")
  assert pairs.count(second) == 1
  assert pairs.exists(second, "BTC/USD")
  assert !pairs.exists(second, "XRP/USD")
}

pub fn non_owner_can_read_but_cannot_write_pairs_test() {
  let assert Ok(store) = pairs.new()
  pairs.apply_changes(
    store,
    added: set.from_list(["BTC/USD"]),
    removed: set.new(),
  )
  let replies = process.new_subject()

  let _ =
    process.spawn(fn() {
      let listed = pairs.exists(store, "BTC/USD")
      let mutation =
        exception.rescue(fn() {
          pairs.apply_changes(
            store,
            added: set.from_list(["ETH/USD"]),
            removed: set.new(),
          )
        })
      process.send(replies, #(listed, mutation))
    })

  let assert Ok(#(True, Error(exception.Errored(reason)))) =
    process.receive(replies, 1000)
  assert decode.run(reason, atom.decoder()) == Ok(atom.create("badarg"))
  assert pairs.count(store) == 1
  assert !pairs.exists(store, "ETH/USD")
}
