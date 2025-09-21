/// A subscription counter for tracking client interest in symbols and managing
/// subscription requests to the Kraken WebSocket API.
///
/// This module tracks how many clients are interested in each symbol and 
/// determines when the single Kraken client should send subscribe/unsubscribe 
/// requests. It ensures that only one subscription per symbol is maintained with 
/// Kraken, regardless of how many clients want that symbol.
///
/// ## Key Invariants
///
/// 1. **Exclusive States**: A symbol cannot exist in both `pending` and `active`
///    dictionaries simultaneously. Symbols are either:
///    - Not tracked at all (in neither dict)
///    - Pending subscription (in `pending` only)  
///    - Actively subscribed (in `active` only)
///
/// 2. **Non-Zero Counts**: All counts stored in the dictionaries are ≥ 1.
///    When a count would reach 0, the entry is deleted entirely using `dict.delete`.
///
/// 3. **State Transitions**: Symbols move through states in a specific order:
///    ```
///    Not tracked → Pending (via add_subscription) → Active (via confirm_subscription)
///                     ↓                                ↓
///                 Deleted (via remove_subscription when count reaches 0)
///    ```
///
/// ## Usage Pattern
///
/// 1. Call `add_subscription` when a client wants a symbol
///    - Returns `True` on first request (Kraken client should subscribe)
///    - Returns `False` on subsequent requests (just increment reference count)
///
/// 2. Call `confirm_subscription` when Kraken confirms the subscription
///    - Moves symbol from `pending` to `active`
///
/// 3. Call `remove_subscription` when a server client no longer wants a symbol  
///    - Returns `True` when removing the last interest (Kraken client should unsubscribe)
///    - Returns `False` when other server clients still interested (just decrement reference count)
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import server/utils/logger.{type Logger}

pub opaque type SubscriptionCounter {
  SubscriptionCounter(pending: Dict(String, Int), active: Dict(String, Int))
}

pub fn new() -> SubscriptionCounter {
  SubscriptionCounter(dict.new(), dict.new())
}

/// Add a subscription request for a symbol
/// 
/// Returns a tuple containing:
/// - `Bool`: Whether the caller should send a subscribe request to Kraken
///   - `True` if this is the first subscription request for this symbol
///   - `False` if the symbol already has pending or active subscriptions
/// - `SubscriptionCounter`: The updated counter with the subscription added
/// 
/// Behavior:
/// - **First subscription for symbol**: returns `(True, counter_with_symbol_in_pending_count_1)`
/// - **Symbol already pending**: returns `(False, counter_with_incremented_pending_count)`
/// - **Symbol already active**: returns `(False, counter_with_incremented_active_count)`
pub fn add_subscription(counter: SubscriptionCounter, symbol: String) {
  let pending_count = get_pending_count(counter, symbol)
  let active_count = get_active_count(counter, symbol)

  use <- bool.guard(active_count > 0, #(
    False,
    SubscriptionCounter(
      counter.pending,
      dict.insert(counter.active, symbol, active_count + 1),
    ),
  ))

  case pending_count {
    0 -> #(
      True,
      SubscriptionCounter(
        dict.insert(counter.pending, symbol, 1),
        counter.active,
      ),
    )

    _ -> #(
      False,
      SubscriptionCounter(
        dict.insert(counter.pending, symbol, pending_count + 1),
        counter.active,
      ),
    )
  }
}

/// Confirm that a subscription has been successfully established with Kraken
/// 
/// This moves all pending subscriptions for a symbol to the active state.
/// Should be called when Kraken sends a subscription confirmation message.
/// 
/// Returns:
/// - `Ok(SubscriptionCounter)`: Updated counter with the symbol moved from pending to active
/// - `Error(Nil)`: If the symbol has no pending subscriptions to confirm
/// 
/// Behavior:
/// - **Symbol has pending subscriptions**: All pending subscriptions become active subscriptions
/// - **Symbol has no pending subscriptions**: Returns `Error(Nil)`
/// - **Symbol already has active subscriptions**: Panics (violates invariant)
pub fn confirm_subscription(
  counter: SubscriptionCounter,
  symbol: String,
) -> Result(SubscriptionCounter, Nil) {
  let assert Error(_) = dict.get(counter.active, symbol)

  let pending_count = get_pending_count(counter, symbol)
  case pending_count == 0 {
    False ->
      Ok(SubscriptionCounter(
        dict.delete(counter.pending, symbol),
        dict.insert(counter.active, symbol, pending_count),
      ))

    True -> Error(Nil)
  }
}

/// Remove a subscription request for a symbol
/// 
/// Returns a tuple containing:
/// - `Bool`: Whether the caller should send an unsubscribe request to Kraken
///   - `True` if this was the last subscription for the symbol (either pending or active)
///   - `False` if there are still other subscriptions for this symbol, or if the symbol wasn't tracked
/// - `SubscriptionCounter`: The updated counter with the subscription removed
/// 
/// Behavior:
/// - If the symbol has no subscriptions: returns `(False, unchanged_counter)`
/// - If removing the last pending subscription: returns `(True, counter_with_symbol_removed_from_pending)`  
/// - If removing one of multiple pending subscriptions: returns `(False, counter_with_decremented_pending)`
/// - If removing the last active subscription: returns `(True, counter_with_symbol_removed_from_active)`
/// - If removing one of multiple active subscriptions: returns `(False, counter_with_decremented_active)`
pub fn remove_subscription(
  counter: SubscriptionCounter,
  symbol: String,
) -> #(Bool, SubscriptionCounter) {
  let pending_count = get_pending_count(counter, symbol)
  let active_count = get_active_count(counter, symbol)

  // Early return for untracked symbols
  let total_count = pending_count + active_count
  use <- bool.guard(total_count == 0, #(False, counter))

  let should_unsubscribe = total_count == 1

  // Handle both dictionaries (only one will have a non-zero count due to invariant #1)
  let pending = case pending_count {
    0 -> counter.pending
    1 -> dict.delete(counter.pending, symbol)
    count -> dict.insert(counter.pending, symbol, count - 1)
  }

  let active = case active_count {
    0 -> counter.active
    1 -> dict.delete(counter.active, symbol)
    count -> dict.insert(counter.active, symbol, count - 1)
  }

  #(should_unsubscribe, SubscriptionCounter(pending:, active:))
}

/// Check if a symbol has any active subscriptions
pub fn is_actively_subscribed(
  counter: SubscriptionCounter,
  symbol: String,
) -> Bool {
  get_active_count(counter, symbol) > 0
}

pub fn get_active_count(counter: SubscriptionCounter, symbol: String) -> Int {
  get_count(counter.active, symbol)
}

pub fn get_pending_count(counter: SubscriptionCounter, symbol: String) -> Int {
  get_count(counter.pending, symbol)
}

fn get_count(dict: Dict(String, Int), symbol: String) -> Int {
  case dict.get(dict, symbol) {
    Error(_) -> 0
    Ok(i) -> i
  }
}

// logging

pub fn log_subscription_count(
  counter: SubscriptionCounter,
  logger: Logger,
  symbol: String,
) -> Nil {
  let pending_count = get_pending_count(counter, symbol)
  let active_count = get_active_count(counter, symbol)

  logger
  |> logger.with("symbol", symbol)
  |> logger.with("subscription_counter.pending", int.to_string(pending_count))
  |> logger.with("subscription_counter.active", int.to_string(active_count))
  |> logger.debug("Subscription count for " <> symbol)

  Nil
}
