# The DevTools port

A person can turn on a port that speaks the Chrome DevTools Protocol, so that an
agent running in a web page, such as SLICC, can drive other tabs. It exists for
iPhone and iPad, where an app has no other way in, and works on the Mac too. It
is off at every launch and lasts until the person turns it off.

## Pieces

| Piece | Owns |
| --- | --- |
| `DevToolsServer`, `DevToolsConnection`, `DevToolsWebSocket` | The loopback listener, HTTP discovery, and WebSocket framing |
| `DevToolsGate` | What may reach the port |
| `DevToolsClient` | One socket's sessions, and the `Browser` and `Target` domains |
| `DevToolsPageSession` | One attachment to a page, which an engine answers |
| `WebKitDevToolsPage`, `WebKitDevToolsDocument`, `WebKitDevToolsRuntime` | The protocol emulated over `WKWebView` |
| `EngineDevToolsPage` | Messages passed through to an engine's own agent, which is Chromium's |
| `DevToolsCertificate`, `DevToolsPin` | The port's certificate, and which pages trust it |
| `MobileBrowserDevTools`, `BrowserMacDevTools` | What each platform exposes, through its own stores |

Clients use one browser socket and flat sessions: attach with `flatten: true`
and send a top-level `sessionId`. There is no `/devtools/page/<id>` socket.

## Who gets in

The port binds to loopback and answers under an unguessable token, in the path:
`/<token>/json/version` and `/devtools/browser/<token>`. `DevToolsGate` also
checks `Host`, against DNS rebinding, and `Origin`, against web pages. A browser
obeys those two, but any program on the device can forge them, so the token is
what lets a client in. Crest hands it only to the main frame of a page of an
allowed origin, as `crestDevTools`, and raises `crestdevtools` on the page when
it arrives after the page started.

```js
const socket = new WebSocket(crestDevTools.webSocketDebuggerUrl);
```

## TLS

WebKit refuses `http` and `ws` to loopback from an `https` page, even with
App Transport Security's exceptions, and accepts `https` and `wss` once the
page's navigation delegate trusts the server. So a port for `WKWebView` pages
speaks TLS with a self-signed certificate made when the port opens. `DevToolsPin`
accepts exactly that certificate, and only for a page of an allowed origin, so
every other page fails at TLS before it can send anything.

Chromium allows plain `ws` to loopback, so the Mac opens a plain port for
Chromium's pages and tools, and a TLS port for WebKit's pages.

## What a client can see

A client sees the tabs of unlocked Spaces, which on iPhone and iPad means the
Spaces windows show. It never sees a private window, a locked Space, or a page
of an allowed origin, which are the clients' own: those pages hold what an agent
must not read, so they can't be attached to or navigated to, and their cookies
aren't reported. A page a client touched can't navigate into such an origin,
which its navigation delegate refuses.

## WebKit's limits

`WKWebView` exposes no protocol to an app, so these differ from Chromium:

- **Input is DOM events**, which a page can tell from the person's own. WebKit
  makes no trusted input for an app. A client that checks `isTrusted` and
  dispatches its own events, as Slicc's does, has `Input` acknowledged and
  dropped, so one click isn't delivered twice. Slicc identifies itself with
  `Slicc.action`.
- **Only the main frame** can be driven. `Page.getFrameTree` and `DOM.getDocument`
  still list a page's frames, so a client can tell what it embeds. They come from
  the DOM, open shadow roots included, and from the document's resource timeline
  and the navigation delegate, which is all a closed shadow root gives up. The
  delegate alone sees a frame nested in a cross-origin frame, and only from when
  the port opened, so a page already loaded by then can hide one until it reloads.
  `Page.createIsolatedWorld` refuses a child frame.
- **Only documents can be paused.** `WKWebView` can't pause a request, but a
  navigation delegate can hold a navigation, so `Fetch.enable` with `Document`
  patterns raises real `Fetch.requestPaused` events and answers
  `continueRequest` and `failRequest`. A document that's held never loads, and a
  client that doesn't answer is refused. The answer carries
  `holdsDocuments: true`. Anything wider fails with `error.data` of
  `documents-only`, so a client can tell this from other failures. A popup a
  page opens runs in a page of its own, which a hold doesn't cover: `WKWebView`
  needs the new view at once, so the popup can't wait for an answer. It loads with
  the person's cookies, and a client can't reach a protected one. This is accepted.
- **Network events are reports** of finished resources, with no headers or
  bodies, from `PerformanceObserver`.
- **Dialogs** go to a client that enabled `Page`, as `Page.javascriptDialogOpening`,
  and are dismissed if it doesn't answer within 10 seconds. Without such a client
  the person answers them, in Crest's own UI. A leave-page question stays with the
  person.
- **`Target.setAutoAttach`** answers *not found* on a page session, deliberately.
  `WKWebView` has no frame targets to attach to, and a client's guard reads that
  answer to fail closed on a page with iframes. Don't answer it as a no-op: that
  promises child sessions that never come, and lifts the guard's lock.
- **A new document's scripts** run once it commits, so a page's first inline
  scripts may run first.

## What `holdsDocuments` promises

`Fetch.enable` answers `holdsDocuments: true`, and clients take that on Crest's word
because they can't check it. Slicc's node and seven's guard both rely on these, and
slicc-cli's README keeps the same list, so a change that breaks one must stop sending
the field:

- Each matching document, in any frame, waits for the client's answer, and one that
  gets no answer doesn't load. That includes a child frame restored from history:
  WebKit asks the navigation delegate for it, as measured on a page evicted from the
  back-forward cache. A page restored from that cache loads nothing, so it brings back
  only what was already let through.
- The hold on a client's own session stays in place whatever other sessions do,
  including their interception, bypass and observation. `Network.setBypassServiceWorker`
  changes nothing here, and `Fetch` and `Network` have no browser-level commands.
- `Input` stays in the main document and never reaches a child frame.
- `Page.getFrameTree` and `DOM.getDocument` list child frames by address, and never
  return a child frame's content.
- That frame evidence gives every frame its `url` and `securityOrigin`, within the
  limits below. Addresses a frame left stay listed until the page's next document, so
  the list can only say too much.
- `Runtime.callFunctionOn`, `Runtime.getProperties`, `Accessibility` and the other
  allowed `DOM` commands, on any object including one for a frame's window, stay in
  the main document and never cross into a child frame.
- `Runtime.evaluate` keeps the page's same-origin rules, and so does every world
  `Page.createIsolatedWorld` makes. `grantUniveralAccess` is ignored.
- Cookie answers report a cookie's real `domain`. `Network.getCookies` defaults to the
  page and its frames and follows the rules of a request: host-only and domain cookies,
  paths on their separators, and secure cookies only to secure addresses. A cookie
  write goes where it says, never to the active tab, and fails when its `url` and
  `domain` disagree. `Network.deleteCookies` needs a `url` or `domain`.
- Target and history evidence is truthful, and `Target.createTarget` makes a new tab
  at the given address.

### Where the promises stop

Clients should know these, because Crest can't remove them:

- **Cookie partitions.** Neither `HTTPCookie` nor `WKHTTPCookieStore` says whether a
  cookie is partitioned, so answers have no `partitionKey`, and a missing key doesn't
  prove there's no partition. A write with `partitionKey` fails.
- **Frames from before the port.** A frame nested inside a cross-origin frame is known
  only from the navigation delegate, which records it while the port is open. One
  loaded before that isn't listed. Frames that a page can see for itself are.
- **A child frame's origin.** `securityOrigin` comes from the frame's `url`, not from its
  document, which no API reports. A frame loaded before the port opened shows the
  address it asked for, even if a redirect took it elsewhere. While the port is open,
  the redirect's address is listed too, because the navigation delegate sees each hop.
- **Frames that failed.** `unreachableUrl` is never sent. WebKit doesn't report a child
  frame's failure, so `url` stays the address the frame asked for, which hides nothing.
- **Bodies and correlation.** `Network.getResponseBody` is refused, because `WKWebView`
  doesn't expose bodies. `Fetch.requestPaused`'s `networkId` matches no `Network` event,
  since those come from the page's own timeline and have ids of their own.

Child frames have ids that stand for an address, since `WKWebView` names no frame.
Two frames at one address share an id on `Fetch.requestPaused` and `Page.frameNavigated`.
`Page.frameAttached` and `Page.frameNavigated` come when a child frame is let through,
since no delegate call follows its commit, so one that then fails was still reported.

## iOS lifetime

iOS suspends a web view no window holds, so while the port is on,
`MobileBrowserDevTools` keeps the pages involved in a window, behind the browser.
It can't keep Crest itself running: the port stops when Crest leaves the
foreground, and reopens with a new token when it returns. A client that was
connected must connect again.

## Vault store

SLICC's vault runs in a frame inside SEVEN and keeps its records in IndexedDB.
WebKit holds a cross-origin frame's storage in memory, so those records are gone
when Crest quits, and the person enters their keys again. This is separate from
the port, and works with the port off.

`BrowserVaultStore` keeps each Space's entries for an origin in a file sealed
with AES-GCM, excluded from backup, with a key per Space in the device-only
Keychain. Deleting a Space deletes both. The sealed data is bound to its Space and
origin, so a file can't be moved to stand in for another.

A page reaches it through `webkit.messageHandlers.crestVaultStore.postMessage`,
which answers with a promise:

| Call | Answer |
| --- | --- |
| `{op: "get", key}` | The string, or null |
| `{op: "put", key, value}` | true |
| `{op: "delete", key}` | true |
| `{op: "list"}` | The keys, sorted |

Failures reject with `EACCES`, `EINVAL` or `EIO`. An origin keeps at most 16 MiB
in a Space, and `EIO` is also what a call over that limit gets.

Two lists decide who gets through. `devTools.allowedOrigins` names the pages that
are offered the handler at all, so an ordinary site doesn't see it.
`devTools.vaultOrigins`, `https://vault.sliccy.ai` by default, names the frames it
answers, judged by the origin WebKit reports for the sender. SEVEN's own page is
refused: an agent runs there, and the vault exists to keep values from it.

Private windows and ephemeral sessions get no handler, since their storage is
meant to end with them. This is iOS only: SEVEN on a Mac has Chrome.

## Chromium

Pass-through needs a client inside the engine, `PageDevTools` in the overlay. It
reaches one page's agent host, as an untrusted client, and `EngineDevToolsPage`
refuses what would reach past that page. It is an engine input, so it ships only
with a new published engine.
