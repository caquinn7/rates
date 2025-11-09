import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/element/svg
import lustre/event

pub type ButtonDropdown(msg) {
  ButtonDropdown(
    id: String,
    button: Button(msg),
    dropdown: Dropdown(msg),
    show_dropdown: Bool,
  )
}

pub type Button(msg) {
  Button(text: String, on_click: msg)
}

pub type Dropdown(msg) {
  Dropdown(
    filter: String,
    options: List(#(String, List(DropdownOption(msg)))),
    mode: DropdownMode,
    on_filter: fn(String) -> msg,
    on_keydown: fn(String) -> msg,
    on_option_click: fn(String) -> msg,
  )
}

pub type DropdownOption(msg) {
  DropdownOption(value: String, display: Element(msg), is_focused: Bool)
}

pub type DropdownMode {
  Grouped
  Flat
}

pub type NavKey {
  ArrowUp
  ArrowDown
  Enter
  Other(String)
}

pub fn calculate_next_focused_index(
  current_index: Option(Int),
  key: NavKey,
  option_count: Int,
) -> Option(Int) {
  use <- bool.guard(option_count == 0, None)

  current_index
  |> option.map(fn(index) {
    case key {
      ArrowDown -> { index + 1 } % option_count
      ArrowUp -> { index - 1 + option_count } % option_count
      _ -> index
    }
  })
  |> option.or(case key {
    ArrowDown -> Some(0)
    ArrowUp -> Some(option_count - 1)
    _ -> None
  })
}

pub fn view(button_dropdown: ButtonDropdown(msg)) -> Element(msg) {
  html.div([attribute.class("relative"), attribute.id(button_dropdown.id)], [
    button(button_dropdown.button),
    dropdown(button_dropdown.dropdown, button_dropdown.show_dropdown),
  ])
}

fn button(button: Button(msg)) -> Element(msg) {
  html.button(
    [
      attribute.class("inline-flex items-center px-3 py-3"),
      attribute.class(
        "w-full rounded-r-lg border-2 border-base-content cursor-pointer",
      ),
      attribute.class(
        "font-normal text-3xl text-left bg-base-content text-secondary-content",
      ),
      event.on_click(button.on_click),
    ],
    [
      html.text(button.text),
      svg.svg(
        [
          attribute.attribute("viewBox", "0 0 20 20"),
          attribute.attribute("xmlns", "http://www.w3.org/2000/svg"),
          attribute.class("ml-2 h-6 w-6 fill-current"),
        ],
        [
          svg.path([
            attribute.attribute(
              "d",
              "M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z",
            ),
          ]),
        ],
      ),
    ],
  )
}

fn dropdown(dropdown: Dropdown(msg), visible: Bool) -> Element(msg) {
  let filter_elem =
    filter_input(dropdown.filter, dropdown.on_filter, dropdown.on_keydown)

  let options_elem = case dropdown.mode {
    Flat ->
      dropdown.options
      |> list.flat_map(pair.second)
      |> options_container(dropdown.on_option_click)

    Grouped ->
      dropdown.options
      |> list.filter(fn(group) { !list.is_empty(pair.second(group)) })
      |> list.map(option_group(_, dropdown.on_option_click))
      |> element.fragment
  }

  html.div(
    [
      attribute.class(
        "absolute z-10 border rounded-lg shadow-lg bg-base-100 max-h-64 overflow-y-auto",
      ),
      attribute.class(
        "min-w-max left-1/2 transform -translate-x-1/2 w-auto translate-y-3",
      ),
      attribute.hidden(!visible),
    ],
    [filter_elem, options_elem],
  )
}

fn filter_input(
  value: String,
  on_input: fn(String) -> msg,
  on_keydown: fn(String) -> msg,
) -> Element(msg) {
  let search_icon =
    svg.svg(
      [
        attribute.class(
          "absolute left-2 top-1/2 -translate-y-1/2 h-4 w-4 pointer-events-none",
        ),
        attribute.attribute("xmlns", "http://www.w3.org/2000/svg"),
        attribute.attribute("fill", "none"),
        attribute.attribute("viewBox", "0 0 24 24"),
        attribute.attribute("stroke-width", "2"),
        attribute.attribute("stroke", "currentColor"),
      ],
      [
        svg.path([
          attribute.attribute("stroke-linecap", "round"),
          attribute.attribute("stroke-linejoin", "round"),
          attribute.attribute(
            "d",
            "M21 21l-4.35-4.35M11 18a7 7 0 1 1 0-14 7 7 0 0 1 0 14z",
          ),
        ]),
      ],
    )

  html.div([attribute.class("relative")], [
    html.input([
      attribute.type_("text"),
      attribute.class(
        "w-full p-2 pl-8 border-b focus:outline-none bg-base-100 text-base-content",
      ),
      attribute.value(value),
      event.on_input(on_input),
      event.on_keydown(on_keydown),
    ]),
    search_icon,
  ])
}

fn option_group(
  group: #(String, List(DropdownOption(msg))),
  on_option_click: fn(String) -> msg,
) -> Element(msg) {
  let #(title, options) = group

  let group_title_div =
    html.div([attribute.class("px-2 py-1 font-semi-bold text-lg")], [
      html.text(title),
    ])

  html.div([], [group_title_div, options_container(options, on_option_click)])
}

fn options_container(
  options: List(DropdownOption(msg)),
  on_option_click: fn(String) -> msg,
) -> Element(msg) {
  keyed.div(
    [attribute.class("options-container")],
    list.map(options, fn(opt) {
      let child = option(opt, on_option_click)
      #(opt.value, child)
    }),
  )
}

fn option(
  option: DropdownOption(msg),
  on_click: fn(String) -> msg,
) -> Element(msg) {
  html.div(
    [
      attribute.attribute("data-value", option.value),
      attribute.class("dd-option px-6 py-1 cursor-pointer"),
      attribute.class("hover:bg-base-content hover:text-secondary-content"),
      case option.is_focused {
        False -> attribute.none()
        True -> attribute.class("bg-base-content text-secondary-content")
      },
      event.on_click(on_click(option.value)),
    ],
    [option.display],
  )
}
