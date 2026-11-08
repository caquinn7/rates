import client/currency/formatting
import client/side.{type Side, Left, Right}
import client/ui/auto_resize_input.{type InputEvent, InputEvent, Selection}
import client/ui/converter.{
  type AmountInput, type Converter, AmountCommitDue, AmountCommitted, NoEffect,
  ScheduleAmountCommit, UserBlurredAmount, UserEnteredAmount, UserFocusedAmount,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import shared/currency.{Crypto, Fiat}
import shared/numbers/non_negative_float
import shared/numbers/positive_float
import shared/websocket_response.{RateUnavailable}

pub fn entered_digits_survive_blur_and_refocus_for_crypto_and_fiat_test() {
  let cases = [
    #("1.23456789", "1.23456789", "1.23456789", 1.23456789),
    #("1234.567890", "1,234.567890", "1234.567890", 1234.56789),
    #("1.2300", "1.2300", "1.2300", 1.23),
    #("0.", "0", "0", 0.0),
    #(".5000", "0.5000", "0.5000", 0.5),
    #(
      "0.123456789123456789",
      "0.123456789123456789",
      "0.123456789123456789",
      0.12345678912345678,
    ),
    #(
      "9007199254740993",
      "9,007,199,254,740,993",
      "9007199254740993",
      9_007_199_254_740_992.0,
    ),
    #("1.2300e10", "1.2300e10", "1.2300e10", 12_300_000_000.0),
  ]

  list.each([Left, Right], fn(edited_side) {
    list.each([False, True], fn(commit_before_blur) {
      list.each(cases, fn(test_case) {
        let #(text, display, retained, value) = test_case
        let focused = focus(new_mixed_converter(), edited_side)
        let #(pending, revision) = enter_text(focused, edited_side, text)
        let pending = case commit_before_blur {
          True -> commit_draft(pending, edited_side, revision)
          False -> pending
        }
        assert draft_text(pending, edited_side) == text
        assert_rendered_amount(pending, edited_side, text)

        let #(blurred, _) =
          converter.update(
            pending,
            UserBlurredAmount(edited_side, input_event(text)),
          )
        assert amount_input(blurred, edited_side).raw == display
        assert amount_input(blurred, edited_side).entered_text == Some(retained)
        assert_parsed_amount(blurred, edited_side, value)
        assert_rendered_amount(blurred, edited_side, display)

        let calculated_side = side.opposite_side(edited_side)
        let converted = case edited_side {
          Left -> value *. 2.0
          Right -> value /. 2.0
        }
        assert_parsed_amount(blurred, calculated_side, converted)
        assert_calculated_display(blurred, calculated_side)

        let _ =
          list.fold([1, 2, 3], blurred, fn(current, _) {
            let refocused = focus(current, edited_side)
            assert draft_text(refocused, edited_side) == retained
            assert_rendered_amount(refocused, edited_side, retained)
            let #(reblurred, effect) =
              converter.update(
                refocused,
                UserBlurredAmount(edited_side, input_event(retained)),
              )
            assert effect == NoEffect
            assert reblurred.last_edited == edited_side
            assert amount_input(reblurred, edited_side).raw == display
            assert_parsed_amount(reblurred, edited_side, value)
            reblurred
          })
      })
    })
  })
}

pub fn entered_digits_survive_live_rates_errors_and_recovery_test() {
  list.each([Left, Right], fn(edited_side) {
    let focused = focus(new_mixed_converter(), edited_side)
    let #(pending, revision) = enter_text(focused, edited_side, "1.2345678900")
    let committed = commit_draft(pending, edited_side, revision)
    let #(blurred, _) =
      converter.update(
        committed,
        UserBlurredAmount(edited_side, input_event("1.2345678900")),
      )
    let rate_updated =
      converter.with_rate(blurred, Some(positive_float.from_float_unsafe(3.0)))
    let failed = converter.with_rate_error(rate_updated, RateUnavailable)
    let recovered =
      converter.with_rate(failed, Some(positive_float.from_float_unsafe(4.0)))

    [rate_updated, failed, recovered]
    |> list.each(fn(current) {
      assert amount_input(current, edited_side).raw == "1.2345678900"
      assert amount_input(current, edited_side).entered_text
        == Some("1.2345678900")
      assert_parsed_amount(current, edited_side, 1.23456789)
      assert_calculated_display(current, side.opposite_side(edited_side))
    })
  })
}

pub fn finalizing_edits_for_currency_changes_or_rate_loss_preserves_digits_test() {
  list.each([Left, Right], fn(edited_side) {
    list.each([False, True], fn(commit_before_change) {
      let focused = focus(new_mixed_converter(), edited_side)
      let #(pending, revision) = enter_text(focused, edited_side, "1234.567890")
      let pending = case commit_before_change {
        True -> commit_draft(pending, edited_side, revision)
        False -> pending
      }
      let currency_changed =
        converter.with_selected_currency(
          pending,
          edited_side,
          Crypto(3, "Other", "OTH", None),
        )
      let rate_lost = converter.with_rate(pending, None)

      list.each([currency_changed, rate_lost], fn(current) {
        assert amount_input(current, edited_side).active_edit == None
        assert amount_input(current, edited_side).raw == "1,234.567890"
        assert amount_input(current, edited_side).entered_text
          == Some("1234.567890")
        assert converter.update(current, AmountCommitDue(edited_side, revision))
          == #(current, NoEffect)

        let recovered =
          converter.with_rate(
            current,
            Some(positive_float.from_float_unsafe(3.0)),
          )
        assert amount_input(recovered, edited_side).raw == "1,234.567890"
        assert draft_text(focus(recovered, edited_side), edited_side)
          == "1234.567890"
        assert_calculated_display(recovered, side.opposite_side(edited_side))
      })
    })
  })
}

pub fn editing_the_calculated_side_replaces_the_previous_entered_text_test() {
  list.each([Left, Right], fn(edited_side) {
    let focused = focus(new_mixed_converter(), edited_side)
    let #(pending, _) = enter_text(focused, edited_side, "1.2300")
    let #(entered, _) =
      converter.update(
        pending,
        UserBlurredAmount(edited_side, input_event("1.2300")),
      )
    let calculated_side = side.opposite_side(edited_side)
    let inspected = focus(entered, calculated_side)
    assert inspected.last_edited == edited_side
    let #(unmodified, _) =
      converter.update(
        inspected,
        UserBlurredAmount(
          calculated_side,
          input_event(draft_text(inspected, calculated_side)),
        ),
      )
    assert unmodified.last_edited == edited_side
    assert amount_input(unmodified, edited_side).entered_text == Some("1.2300")

    let focused = focus(unmodified, calculated_side)
    let #(pending, _) = enter_text(focused, calculated_side, "5.6700")
    let #(reversed, _) =
      converter.update(
        pending,
        UserBlurredAmount(calculated_side, input_event("5.6700")),
      )
    assert reversed.last_edited == calculated_side
    assert amount_input(reversed, calculated_side).raw == "5.6700"
    assert amount_input(reversed, calculated_side).entered_text
      == Some("5.6700")
    assert_calculated_display(reversed, edited_side)
    let assert Some(parsed) = amount_input(reversed, edited_side).parsed
    assert draft_text(focus(reversed, edited_side), edited_side)
      == non_negative_float.to_string(parsed)
  })
}

pub fn replacing_or_clearing_an_amount_discards_retained_text_test() {
  list.each([Left, Right], fn(edited_side) {
    let focused = focus(new_mixed_converter(), edited_side)
    let #(pending, _) = enter_text(focused, edited_side, "1.2300")
    let #(entered, _) =
      converter.update(
        pending,
        UserBlurredAmount(edited_side, input_event("1.2300")),
      )

    list.each(["2", "", "1,00"], fn(replacement) {
      let replaced = converter.with_amount(entered, edited_side, replacement)
      assert amount_input(replaced, edited_side).entered_text == None
      assert amount_input(replaced, side.opposite_side(edited_side)).entered_text
        == None
    })

    list.each(["", "1,00"], fn(text) {
      let #(pending, _) =
        enter_text(focus(entered, edited_side), edited_side, text)
      let #(cleared, _) =
        converter.update(
          pending,
          UserBlurredAmount(edited_side, input_event(text)),
        )
      assert amount_input(cleared, edited_side).raw == text
      assert amount_input(cleared, edited_side).parsed == None
      assert amount_input(cleared, edited_side).entered_text == None
      assert amount_input(cleared, side.opposite_side(edited_side)).raw == ""
    })
  })
}

pub fn seeded_amounts_keep_existing_formatting_until_edited_test() {
  let assert Ok(original) =
    converter.new(
      "editing-test",
      [Crypto(1, "Bitcoin", "BTC", None), Fiat(2, "US Dollar", "USD", "$")],
      #(1, 2),
      "1.23456789",
      Some(positive_float.from_float_unsafe(2.0)),
    )
  assert amount_input(original, Left).raw == "1.2346"
  assert amount_input(original, Left).entered_text == None
  assert amount_input(original, Right).raw == "2.47"
  assert amount_input(original, Right).entered_text == None
  assert draft_text(focus(original, Left), Left) == "1.23456789"
}

pub fn signed_amounts_are_invalid_on_both_sides_test() {
  list.each([Left, Right], fn(edited_side) {
    list.each([False, True], fn(commit_before_blur) {
      list.each(
        [
          "+1",
          "-1",
          "+0.00",
          "-0.00",
          "+1,234.56",
          "-1,234.56",
          "+1.0e3",
          "-1.0e3",
        ],
        fn(text) {
          let #(pending, revision) =
            enter_text(
              focus(new_mixed_converter(), edited_side),
              edited_side,
              text,
            )
          let current = case commit_before_blur {
            True -> commit_draft(pending, edited_side, revision)
            False -> pending
          }
          assert draft_text(current, edited_side) == text
          let #(blurred, _) =
            converter.update(
              current,
              UserBlurredAmount(edited_side, input_event(text)),
            )
          assert amount_input(blurred, edited_side).raw == text
          assert amount_input(blurred, edited_side).parsed == None
          assert amount_input(blurred, edited_side).entered_text == None
          assert amount_input(blurred, side.opposite_side(edited_side)).raw
            == ""
          assert amount_input(blurred, side.opposite_side(edited_side)).parsed
            == None
          assert_rendered_amount(blurred, edited_side, text)
        },
      )
    })
  })
}

pub fn correcting_a_signed_amount_restores_conversion_and_retains_zeros_test() {
  list.each([Left, Right], fn(edited_side) {
    list.each([False, True], fn(commit_before_blur) {
      list.each(["+1.2300", "-1.2300"], fn(signed) {
        let #(pending, _) =
          enter_text(
            focus(new_mixed_converter(), edited_side),
            edited_side,
            signed,
          )
        let #(invalid, _) =
          converter.update(
            pending,
            UserBlurredAmount(edited_side, input_event(signed)),
          )
        let #(corrected, revision) =
          enter_text(focus(invalid, edited_side), edited_side, "1.2300")
        let corrected = case commit_before_blur {
          True -> commit_draft(corrected, edited_side, revision)
          False -> corrected
        }
        let #(blurred, _) =
          converter.update(
            corrected,
            UserBlurredAmount(edited_side, input_event("1.2300")),
          )
        assert amount_input(blurred, edited_side).raw == "1.2300"
        assert amount_input(blurred, edited_side).entered_text == Some("1.2300")
        assert_parsed_amount(blurred, edited_side, 1.23)
        let converted = case edited_side {
          Left -> 2.46
          Right -> 0.615
        }
        assert_parsed_amount(
          blurred,
          side.opposite_side(edited_side),
          converted,
        )
        assert_rendered_amount(blurred, edited_side, "1.2300")
        let refocused = focus(blurred, edited_side)
        assert draft_text(refocused, edited_side) == "1.2300"
        assert_rendered_amount(refocused, edited_side, "1.2300")
        let #(reblurred, _) =
          converter.update(
            refocused,
            UserBlurredAmount(edited_side, input_event("1.2300")),
          )
        assert amount_input(reblurred, edited_side).raw == "1.2300"
      })
    })
  })
}

pub fn focus_reveals_ungrouped_value_without_changing_driver_test() {
  let original = new_converter()
  let cases = [#(Left, "1000"), #(Right, "2000")]

  list.each(cases, fn(test_case) {
    let #(edited_side, expected_draft) = test_case
    let focused = focus(original, edited_side)

    assert draft_text(focused, edited_side) == expected_draft
    assert amount_input(focused, edited_side).parsed
      == amount_input(original, edited_side).parsed
    assert focused.last_edited == original.last_edited
  })
}

pub fn append_and_backspace_remain_valid_until_blur_test() {
  let cases = [#("10001", 10_001.0, "10,001"), #("100", 100.0, "100")]

  list.each([Left, Right], fn(edited_side) {
    // Start either field at 1,000 so these edits append or remove one digit.
    let original = converter.with_amount(new_converter(), edited_side, "1000")
    let focused = focus(original, edited_side)

    list.each(cases, fn(test_case) {
      let #(text, expected_amount, expected_display) = test_case
      let #(pending, revision) = enter_text(focused, edited_side, text)
      let committed = commit_draft(pending, edited_side, revision)

      assert draft_text(committed, edited_side) == text
      assert_parsed_amount(committed, edited_side, expected_amount)

      let #(blurred, effect) =
        converter.update(
          committed,
          UserBlurredAmount(edited_side, input_event(text)),
        )

      assert amount_input(blurred, edited_side).raw == expected_display
      assert amount_input(blurred, edited_side).active_edit == None
      assert effect == NoEffect
    })
  })
}

pub fn draft_keeps_decimal_points_and_trailing_zeros_after_commit_test() {
  let cases = [
    #("123.", 123.0),
    #("123.45", 123.45),
    #("123.4500", 123.45),
    #(".5", 0.5),
  ]

  list.each([Left, Right], fn(edited_side) {
    let focused = focus(new_converter(), edited_side)

    list.each(cases, fn(test_case) {
      let #(text, expected_amount) = test_case
      let #(pending, revision) = enter_text(focused, edited_side, text)
      let committed = commit_draft(pending, edited_side, revision)

      assert draft_text(committed, edited_side) == text
      assert_parsed_amount(committed, edited_side, expected_amount)
    })
  })
}

pub fn grouped_paste_is_validated_then_ungrouped_with_selection_test() {
  list.each([Left, Right], fn(edited_side) {
    let focused = focus(new_converter(), edited_side)
    let pasted_text =
      InputEvent("12,345.600", selection_start: 4, selection_end: 7)
    let #(pending, effect) =
      converter.update(focused, UserEnteredAmount(edited_side, pasted_text))

    let assert ScheduleAmountCommit(_, revision) = effect
    let assert Some(active_edit) =
      amount_input(pending, edited_side).active_edit

    assert active_edit.draft == "12345.600"
    assert active_edit.selection
      == Some(Selection(value: "12345.600", start: 3, end: 6, revision:))
  })
}

pub fn malformed_paste_stays_invalid_through_commit_and_blur_test() {
  let invalid_inputs = ["1,00", ",123", "1,234.5,6", "1.."]

  list.each([Left, Right], fn(edited_side) {
    let opposite_side = side.opposite_side(edited_side)
    let focused = focus(new_converter(), edited_side)

    list.each(invalid_inputs, fn(invalid_text) {
      let #(pending, revision) = enter_text(focused, edited_side, invalid_text)
      assert draft_text(pending, edited_side) == invalid_text

      let committed = commit_draft(pending, edited_side, revision)
      assert amount_input(committed, edited_side).parsed == None
      assert amount_input(committed, opposite_side).raw == ""

      let #(blurred, _) =
        converter.update(
          committed,
          UserBlurredAmount(edited_side, input_event(invalid_text)),
        )

      assert amount_input(blurred, edited_side).raw == invalid_text
      assert amount_input(blurred, edited_side).active_edit == None
    })
  })
}

pub fn focus_preserves_full_stored_precision_and_magnitude_test() {
  let amounts = ["0.12345678912345678", "1.23456789", "1.0e-310", "1.0e21"]

  list.each([Left, Right], fn(edited_side) {
    list.each(amounts, fn(text) {
      let original = converter.with_amount(new_converter(), edited_side, text)
      let focused = focus(original, edited_side)
      let editing_text = draft_text(focused, edited_side)
      let assert Ok(parsed_draft) = non_negative_float.parse(editing_text)

      assert Some(parsed_draft) == amount_input(original, edited_side).parsed

      let #(blurred, effect) =
        converter.update(
          focused,
          UserBlurredAmount(edited_side, input_event(editing_text)),
        )

      assert effect == NoEffect
      assert amount_input(blurred, edited_side).parsed
        == amount_input(original, edited_side).parsed
      assert blurred.last_edited == original.last_edited
    })
  })
}

pub fn blur_flushes_latest_dom_text_and_invalidates_pending_commit_test() {
  list.each([Left, Right], fn(edited_side) {
    let focused = focus(new_converter(), edited_side)
    let #(pending, old_revision) = enter_text(focused, edited_side, "12")

    // Blur reports newer DOM text than the last input event delivered.
    let #(blurred, effect) =
      converter.update(
        pending,
        UserBlurredAmount(edited_side, input_event("123.")),
      )

    assert effect == AmountCommitted
    assert amount_input(blurred, edited_side).raw == "123"
    assert_parsed_amount(blurred, edited_side, 123.0)
    assert converter.update(blurred, AmountCommitDue(edited_side, old_revision))
      == #(blurred, NoEffect)

    let refocused = focus(blurred, edited_side)
    let #(new_pending, new_revision) = enter_text(refocused, edited_side, "456")

    assert new_revision > old_revision
    assert converter.update(
        new_pending,
        AmountCommitDue(edited_side, old_revision),
      )
      == #(new_pending, NoEffect)

    let committed = commit_draft(new_pending, edited_side, new_revision)
    assert draft_text(committed, edited_side) == "456"
    assert_parsed_amount(committed, edited_side, 456.0)
  })
}

pub fn only_latest_revision_commits_test() {
  let focused = focus(new_converter(), Left)

  let #(first_edit, old_revision) = enter_text(focused, Left, "100")
  let #(latest_edit, latest_revision) = enter_text(first_edit, Left, "200")

  assert converter.update(latest_edit, AmountCommitDue(Left, old_revision))
    == #(latest_edit, NoEffect)

  let committed = commit_draft(latest_edit, Left, latest_revision)
  assert_parsed_amount(committed, Left, 200.0)
}

pub fn pending_draft_waits_for_debounce_and_uses_latest_rate_test() {
  let cases = [#(Left, "3,600"), #(Right, "400")]

  list.each(cases, fn(test_case) {
    let #(edited_side, expected_conversion) = test_case
    let opposite_side = side.opposite_side(edited_side)
    let focused = focus(new_converter(), edited_side)

    let #(pending, revision) = enter_text(focused, edited_side, "1200")

    let rate_updated =
      converter.with_rate(pending, Some(positive_float.from_float_unsafe(3.0)))

    assert draft_text(rate_updated, edited_side) == "1200"
    assert amount_input(rate_updated, opposite_side)
      == amount_input(pending, opposite_side)

    let committed = commit_draft(rate_updated, edited_side, revision)
    assert amount_input(committed, opposite_side).raw == expected_conversion
    assert draft_text(committed, edited_side) == "1200"
  })
}

pub fn invalid_draft_survives_live_rates_and_can_be_corrected_test() {
  let cases = [#(Left, "360"), #(Right, "40")]

  list.each(cases, fn(test_case) {
    let #(edited_side, expected_conversion) = test_case
    let opposite_side = side.opposite_side(edited_side)
    let focused = focus(new_converter(), edited_side)
    let #(pending, revision) = enter_text(focused, edited_side, "1,00")
    let invalid = commit_draft(pending, edited_side, revision)

    let rate_updated =
      converter.with_rate(invalid, Some(positive_float.from_float_unsafe(3.0)))

    assert draft_text(rate_updated, edited_side) == "1,00"
    assert amount_input(rate_updated, opposite_side).raw == ""

    let #(corrected, revision) = enter_text(rate_updated, edited_side, "120")
    let committed = commit_draft(corrected, edited_side, revision)
    assert amount_input(committed, opposite_side).raw == expected_conversion
  })
}

pub fn committed_draft_and_selection_survive_live_rates_test() {
  list.each([Left, Right], fn(edited_side) {
    let focused = focus(new_converter(), edited_side)
    let #(pending, revision) = enter_text(focused, edited_side, "120.00")
    let committed = commit_draft(pending, edited_side, revision)

    let rate_updated =
      converter.with_rate(
        committed,
        Some(positive_float.from_float_unsafe(3.0)),
      )

    assert draft_text(rate_updated, edited_side) == "120.00"
    assert amount_input(rate_updated, edited_side).active_edit
      == amount_input(committed, edited_side).active_edit
    assert amount_input(rate_updated, edited_side).parsed
      == amount_input(committed, edited_side).parsed

    let #(blurred, effect) =
      converter.update(
        rate_updated,
        UserBlurredAmount(edited_side, input_event("120.00")),
      )

    assert effect == NoEffect
    assert amount_input(blurred, edited_side).raw == "120.00"
  })
}

pub fn unchanged_input_does_not_change_driver_or_schedule_commit_test() {
  let focused = focus(new_converter(), Right)
  let unchanged_input = UserEnteredAmount(Right, input_event("2000"))

  assert converter.update(focused, unchanged_input) == #(focused, NoEffect)
}

pub fn immediate_untouched_blur_preserves_full_precision_test() {
  list.each([Left, Right], fn(edited_side) {
    let original =
      converter.with_amount(new_converter(), edited_side, "0.12345678912345678")
    let displayed_text = amount_input(original, edited_side).raw
    let focused = focus(original, edited_side)

    // A fast blur can still report the rounded display from before focus.
    let #(blurred, effect) =
      converter.update(
        focused,
        UserBlurredAmount(edited_side, input_event(displayed_text)),
      )

    assert effect == NoEffect
    assert amount_input(blurred, edited_side).parsed
      == amount_input(original, edited_side).parsed
    assert blurred.last_edited == original.last_edited
  })
}

pub fn untouched_focus_blur_does_not_replace_live_updated_amount_test() {
  let focused = focus(new_converter(), Right)
  let rate_updated =
    converter.with_rate(focused, Some(positive_float.from_float_unsafe(3.0)))

  assert draft_text(rate_updated, Right) == "2000"
  assert amount_input(rate_updated, Right).raw == "3,000"

  let #(blurred, effect) =
    converter.update(
      rate_updated,
      UserBlurredAmount(Right, input_event("2000")),
    )

  assert effect == NoEffect
  assert blurred.last_edited == Left
  assert amount_input(blurred, Right).raw == "3,000"
  assert_parsed_amount(blurred, Right, 3000.0)
}

pub fn losing_rate_finishes_draft_before_disabling_input_test() {
  let focused = focus(new_converter(), Left)
  let #(pending, revision) = enter_text(focused, Left, "123.")
  let rate_removed = converter.with_rate(pending, None)

  assert amount_input(rate_removed, Left).active_edit == None
  assert amount_input(rate_removed, Left).raw == "123"
  assert amount_input(rate_removed, Right).raw == "price not tracked"
  assert converter.update(rate_removed, AmountCommitDue(Left, revision))
    == #(rate_removed, NoEffect)
}

pub fn changing_currency_finishes_draft_and_invalidates_timer_test() {
  let focused = focus(new_converter(), Left)
  let #(pending, revision) = enter_text(focused, Left, "123.")
  let new_currency = Crypto(3, "Other", "OTH", None)
  let currency_changed =
    converter.with_selected_currency(pending, Left, new_currency)

  assert amount_input(currency_changed, Left).active_edit == None
  assert_parsed_amount(currency_changed, Left, 123.0)
  assert converter.update(currency_changed, AmountCommitDue(Left, revision))
    == #(currency_changed, NoEffect)
}

pub fn switching_focus_finishes_previous_pending_edit_test() {
  let focused_left = focus(new_converter(), Left)
  let #(pending, revision) = enter_text(focused_left, Left, "123")
  let focused_right = focus(pending, Right)

  assert amount_input(focused_right, Left).active_edit == None
  assert draft_text(focused_right, Right) == "246"
  assert focused_right.last_edited == Left
  assert converter.update(focused_right, AmountCommitDue(Left, revision))
    == #(focused_right, NoEffect)
}

// The fixture starts with 1,000 BTC = 2,000 ETH, driven by the left field.
fn new_converter() -> Converter {
  let assert Ok(converter) =
    converter.new(
      "editing-test",
      [Crypto(1, "Bitcoin", "BTC", None), Crypto(2, "Ethereum", "ETH", None)],
      #(1, 2),
      "1000",
      Some(positive_float.from_float_unsafe(2.0)),
    )
  converter
}

fn new_mixed_converter() -> Converter {
  let assert Ok(converter) =
    converter.new(
      "editing-test",
      [Crypto(1, "Bitcoin", "BTC", None), Fiat(2, "US Dollar", "USD", "$")],
      #(1, 2),
      "1000",
      Some(positive_float.from_float_unsafe(2.0)),
    )
  converter
}

fn input_event(text: String) -> InputEvent {
  let end = string.length(text)
  InputEvent(value: text, selection_start: end, selection_end: end)
}

fn focus(converter: Converter, side: Side) -> Converter {
  let displayed_text = amount_input(converter, side).raw
  let #(focused, _) =
    converter.update(
      converter,
      UserFocusedAmount(side, input_event(displayed_text)),
    )
  focused
}

fn enter_text(
  converter: Converter,
  side: Side,
  text: String,
) -> #(Converter, Int) {
  let #(pending, effect) =
    converter.update(converter, UserEnteredAmount(side, input_event(text)))
  let assert ScheduleAmountCommit(_, revision) = effect
  #(pending, revision)
}

fn commit_draft(converter: Converter, side: Side, revision: Int) -> Converter {
  let #(committed, effect) =
    converter.update(converter, AmountCommitDue(side, revision))
  let assert AmountCommitted = effect
  committed
}

fn amount_input(converter: Converter, side: Side) -> AmountInput {
  converter.get_converter_input(converter, side).amount_input
}

fn draft_text(converter: Converter, side: Side) -> String {
  let assert Some(active_edit) = amount_input(converter, side).active_edit
  active_edit.draft
}

fn assert_parsed_amount(
  converter: Converter,
  side: Side,
  expected: Float,
) -> Nil {
  let assert Some(parsed) = amount_input(converter, side).parsed
  assert non_negative_float.unwrap(parsed) == expected
}

fn assert_rendered_amount(
  converter: Converter,
  side: Side,
  text: String,
) -> Nil {
  let assert Ok(#(_, input)) =
    string.split_once(
      element.to_string(converter.view(converter)),
      "id=\"amount-input-editing-test-" <> side.to_string(side) <> "\"",
    )
  let assert Ok(#(attributes, _)) = string.split_once(input, ">")
  assert string.contains(attributes, "value=\"" <> text <> "\"")
}

fn assert_calculated_display(converter: Converter, side: Side) -> Nil {
  let input = converter.get_converter_input(converter, side)
  let assert Some(amount) = input.amount_input.parsed
  assert input.amount_input.raw
    == formatting.format_currency_amount(
      input.currency_selector.selected_currency,
      amount,
    )
  assert input.amount_input.entered_text == None
}
