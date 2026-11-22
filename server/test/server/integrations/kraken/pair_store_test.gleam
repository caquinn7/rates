import exception
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/set
import server/integrations/kraken/pair_store

pub fn new_store_starts_empty_test() {
  let assert Ok(store) = pair_store.new()
  assert pair_store.count(store) == 0
  assert !pair_store.exists(store, "BTC/USD")
}

pub fn membership_changes_are_local_to_one_store_test() {
  let assert Ok(first) = pair_store.new()
  let assert Ok(second) = pair_store.new()
  pair_store.apply_changes(
    first,
    added: set.from_list(["BTC/USD", "ETH/USD"]),
    removed: set.new(),
  )
  pair_store.apply_changes(
    second,
    added: set.from_list(["BTC/USD"]),
    removed: set.new(),
  )

  pair_store.apply_changes(
    first,
    added: set.from_list(["XRP/USD"]),
    removed: set.from_list(["BTC/USD"]),
  )

  assert pair_store.count(first) == 2
  assert pair_store.exists(first, "ETH/USD")
  assert pair_store.exists(first, "XRP/USD")
  assert !pair_store.exists(first, "BTC/USD")
  assert pair_store.count(second) == 1
  assert pair_store.exists(second, "BTC/USD")
  assert !pair_store.exists(second, "XRP/USD")
}

pub fn non_owner_can_read_but_cannot_write_pairs_test() {
  let assert Ok(store) = pair_store.new()
  pair_store.apply_changes(
    store,
    added: set.from_list(["BTC/USD"]),
    removed: set.new(),
  )
  let replies = process.new_subject()

  let _ =
    process.spawn(fn() {
      let listed = pair_store.exists(store, "BTC/USD")
      let mutation =
        exception.rescue(fn() {
          pair_store.apply_changes(
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
  assert pair_store.count(store) == 1
  assert !pair_store.exists(store, "ETH/USD")
}
