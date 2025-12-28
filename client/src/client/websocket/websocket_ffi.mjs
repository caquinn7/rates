export function initSocket(url, onOpen, onMessage, onClose) {
  let ws;
  if (typeof WebSocket === "function") {
    ws = new WebSocket(url);
  } else {
    // we're NOT in the browser, prolly running tests
    ws = {};
  }

  // Event
  ws.onopen = _ => onOpen(ws);
  // MessageEvent
  ws.onmessage = event => onMessage(event.data);
  // CloseEvent
  ws.onclose = event => onClose(event.code);
}

export function sendOverSocket(ws, msg) {
  ws.send(msg);
}

export function close(ws) {
  ws.close();
}
