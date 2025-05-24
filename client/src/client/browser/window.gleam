// A long integer value, the request ID, that uniquely identifies the entry in the callback list. This is a non-zero value, but you may not make any other assumptions about its value. You can pass this value to window.cancelAnimationFrame() to cancel the refresh callback request.
pub type RequestID

@external(javascript, "../../window_ffi.mjs", "requestAnimationFrame")
pub fn request_animation_frame(callback: fn(Float) -> Nil) -> RequestID
