import gleam/list
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/element/svg
import lustre/event

pub type DropdownOption(msg) {
  DropdownOption(value: String, display: Element(msg), is_focused: Bool)
}

pub fn view(
  id: String,
  btn_text: String,
  show_dropdown: Bool,
  filter: String,
  options: List(#(String, List(DropdownOption(msg)))),
  on_btn_click: msg,
  on_filter: fn(String) -> msg,
  on_keydown_in_dropdown: fn(String) -> msg,
  on_option_click: fn(String) -> msg,
) -> Element(msg) {
  html.div([attribute.class("relative"), attribute.id(id)], [
    button(btn_text, on_btn_click),
    dropdown(
      show_dropdown,
      filter,
      options,
      on_filter,
      on_keydown_in_dropdown,
      on_option_click,
    ),
  ])
}

pub fn button(text, on_click) -> Element(msg) {
  html.button(
    [
      attribute.class("inline-flex items-center px-3 py-3"),
      attribute.class("w-full rounded-r-lg cursor-pointer"),
      attribute.class(
        "font-light text-4xl text-left bg-primary text-primary-content",
      ),
      event.on_click(on_click),
    ],
    [
      html.text(text),
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

fn dropdown(
  visible: Bool,
  filter: String,
  options: List(#(String, List(DropdownOption(msg)))),
  on_filter: fn(String) -> msg,
  on_keydown_in_dropdown: fn(String) -> msg,
  on_option_click: fn(String) -> msg,
) -> Element(msg) {
  let filter_elem =
    currency_filter_input(filter, on_filter, on_keydown_in_dropdown)
  let option_group_elems = option_groups(options, on_option_click)

  html.div(
    [
      attribute.class(
        "absolute z-10 border rounded-lg shadow-md max-h-64 overflow-y-auto",
      ),
      attribute.class(
        "min-w-max left-1/2 transform -translate-x-1/2 w-auto translate-y-3",
      ),
      attribute.hidden(!visible),
    ],
    [filter_elem, element.fragment(option_group_elems)],
  )
}

fn currency_filter_input(
  value: String,
  on_input: fn(String) -> msg,
  on_keydown_in_dropdown: fn(String) -> msg,
) -> Element(msg) {
  html.input([
    attribute.type_("text"),
    attribute.placeholder("Search..."),
    attribute.class("w-full p-2 border-b focus:outline-none caret-info"),
    attribute.value(value),
    event.on_input(on_input),
    event.on_keydown(on_keydown_in_dropdown),
  ])
}

fn option_groups(
  groups: List(#(String, List(DropdownOption(msg)))),
  on_option_click: fn(String) -> msg,
) -> List(Element(msg)) {
  groups
  |> list.map(option_group(_, on_option_click))
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
      attribute.class("hover:bg-primary hover:text-primary-content"),
      case option.is_focused {
        False -> attribute.none()
        True -> attribute.class("bg-primary text-primary-content")
      },
      event.on_click(on_click(option.value)),
    ],
    [option.display],
  )
}
