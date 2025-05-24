pub type Element

@external(javascript, "../../element_ffi.mjs", "innerText")
pub fn inner_text(element: Element) -> String

@external(javascript, "../../element_ffi.mjs", "nextElementSibling")
pub fn next_element_sibling(element: Element) -> Result(Element, Nil)

@external(javascript, "../../element_ffi.mjs", "copyInputStyles")
pub fn copy_input_styles(from element1: Element, to element2: Element) -> Nil

@external(javascript, "../../element_ffi.mjs", "offsetWidth")
pub fn offset_width(element: Element) -> Int

@external(javascript, "../../element_ffi.mjs", "getComputedStyleProperty")
pub fn get_computed_style_property(
  element: Element,
  property_name: String,
) -> String
