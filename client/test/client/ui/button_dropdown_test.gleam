import client/ui/button_dropdown.{ArrowDown, ArrowUp, Enter, Other}
import gleam/option.{None, Some}

pub fn calculate_next_focused_index_arrow_down_from_none_test() {
  assert Some(0)
    == button_dropdown.calculate_next_focused_index(None, ArrowDown, 5)
}

pub fn calculate_next_focused_index_arrow_up_from_none_test() {
  assert Some(4)
    == button_dropdown.calculate_next_focused_index(None, ArrowUp, 5)
}

pub fn calculate_next_focused_index_arrow_down_wraps_around_test() {
  assert Some(0)
    == button_dropdown.calculate_next_focused_index(Some(4), ArrowDown, 5)
}

pub fn calculate_next_focused_index_arrow_up_wraps_around_test() {
  assert Some(4)
    == button_dropdown.calculate_next_focused_index(Some(0), ArrowUp, 5)
}

pub fn calculate_next_focused_index_arrow_down_moves_forward_test() {
  assert Some(2)
    == button_dropdown.calculate_next_focused_index(Some(1), ArrowDown, 5)
  assert Some(3)
    == button_dropdown.calculate_next_focused_index(Some(2), ArrowDown, 5)
}

pub fn calculate_next_focused_index_arrow_up_moves_backward_test() {
  assert Some(2)
    == button_dropdown.calculate_next_focused_index(Some(3), ArrowUp, 5)
  assert Some(1)
    == button_dropdown.calculate_next_focused_index(Some(2), ArrowUp, 5)
}

pub fn calculate_next_focused_index_enter_key_preserves_index_test() {
  assert Some(2)
    == button_dropdown.calculate_next_focused_index(Some(2), Enter, 5)
  assert None == button_dropdown.calculate_next_focused_index(None, Enter, 5)
}

pub fn calculate_next_focused_index_other_key_preserves_index_test() {
  assert Some(3)
    == button_dropdown.calculate_next_focused_index(Some(3), Other("x"), 5)
  assert None
    == button_dropdown.calculate_next_focused_index(None, Other("Escape"), 5)
}

pub fn calculate_next_focused_index_empty_list_returns_none_test() {
  assert None
    == button_dropdown.calculate_next_focused_index(None, ArrowDown, 0)
  assert None == button_dropdown.calculate_next_focused_index(None, ArrowUp, 0)
  assert None
    == button_dropdown.calculate_next_focused_index(Some(0), ArrowDown, 0)
  assert None
    == button_dropdown.calculate_next_focused_index(Some(2), ArrowUp, 0)
}

pub fn calculate_next_focused_index_single_item_list_test() {
  assert Some(0)
    == button_dropdown.calculate_next_focused_index(None, ArrowDown, 1)
  assert Some(0)
    == button_dropdown.calculate_next_focused_index(None, ArrowUp, 1)
  assert Some(0)
    == button_dropdown.calculate_next_focused_index(Some(0), ArrowDown, 1)
  assert Some(0)
    == button_dropdown.calculate_next_focused_index(Some(0), ArrowUp, 1)
}
