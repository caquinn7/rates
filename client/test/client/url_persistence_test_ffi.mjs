import { toList } from "../gleam.mjs";

let activeBrowser;

export function withBrowser(run) {
  const previousGlobals = ["window", "history", "document", "WebSocket"].map(
    name => [name, Object.getOwnPropertyDescriptor(globalThis, name)],
  );
  const previousBrowser = activeBrowser;
  const browser = {
    url: new URL("https://rates.test/"),
    writes: 0,
    now: 0,
    nextTimerId: 1,
    timers: [],
    messages: [],
    sent: [],
    sockets: [],
  };
  activeBrowser = browser;

  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      get location() { return browser.url; },
      setTimeout(callback, delay) {
        const id = browser.nextTimerId++;
        browser.timers.push({ id, due: browser.now + delay, callback });
        return id;
      },
    },
  });
  Object.defineProperty(globalThis, "document", {
    configurable: true,
    value: { get URL() { return browser.url.href; } },
  });
  Object.defineProperty(globalThis, "WebSocket", {
    configurable: true,
    value: class {
      constructor(url) {
        this.url = url;
        browser.sockets.push(this);
      }
      send(message) {
        browser.sent.push(message);
      }
    },
  });
  Object.defineProperty(globalThis, "history", {
    configurable: true,
    value: {
      replaceState(_state, _title, url) {
        browser.url = new URL(url);
        browser.writes += 1;
      },
    },
  });

  try {
    return run();
  } finally {
    for (const [name, descriptor] of previousGlobals) {
      restoreGlobal(name, descriptor);
    }
    activeBrowser = previousBrowser;
  }
}

function restoreGlobal(name, descriptor) {
  if (descriptor) {
    Object.defineProperty(globalThis, name, descriptor);
  } else {
    delete globalThis[name];
  }
}

export function encodedState() {
  return activeBrowser.url.searchParams.get("state") ?? "";
}

export function urlWriteCount() {
  return activeBrowser.writes;
}

export function socket() {
  const browser = activeBrowser;
  return { send(message) { browser.sent.push(message); } };
}

export function recordMessage(message) {
  activeBrowser.messages.push(message);
}

export function takeMessages() {
  return toList(activeBrowser.messages.splice(0));
}

export function sentMessages() {
  return toList(activeBrowser.sent);
}

export function openSocket() {
  activeBrowser.sockets.at(-1).onopen({});
}

export function pendingTimerCount() {
  return activeBrowser.timers.length;
}

export function advanceTime(milliseconds) {
  const browser = activeBrowser;
  const target = browser.now + milliseconds;
  while (true) {
    browser.timers.sort((a, b) => a.due - b.due || a.id - b.id);
    if (!browser.timers.length || browser.timers[0].due > target) break;
    const timer = browser.timers.shift();
    browser.now = timer.due;
    timer.callback();
  }
  browser.now = target;
}
