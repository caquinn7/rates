import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event

pub type Button(msg) {
  Button(text: String, on_click: msg)
}

pub fn view(button: Button(msg)) -> Element(msg) {
  html.button(
    [
      attribute.class("inline-flex items-center px-6 py-4"),
      attribute.class("w-full rounded-r-lg border bg-neutral"),
      attribute.class("font-light text-4xl text-left text-neutral-content"),
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
