import client/browser/element.{type Element}

pub type ShadowRoot

@external(javascript, "./shadow_root_ffi.mjs", "shadowRoot")
pub fn shadow_root(element: Element) -> ShadowRoot

@external(javascript, "./shadow_root_ffi.mjs", "querySelector")
pub fn query_selector(
  shadow_root: ShadowRoot,
  selector: String,
) -> Result(Element, Nil)
