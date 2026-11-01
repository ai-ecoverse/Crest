import Foundation

/// What a DevTools session keeps inside a document: remote objects and DOM
/// nodes by id, the accessibility tree WebKit doesn't expose, and input as DOM
/// events, since WebKit synthesizes no trusted input for a script. The source
/// is the body of an async function taking `__key`, `__handler`, `__context`,
/// `__nodeSpan` and `__frame`; it stays under the key the session chose, one per document and
/// world. It never compiles text itself, which a page's content security
/// policy could refuse: WebKit compiles the expressions a client sends as part
/// of the script it runs.
enum WebKitDevToolsRuntime {
    // MARK: - Actions - Sources

    /// The runtime as a script of its own for the start of every document, so
    /// it hears a page's first console messages and requests. It can't take
    /// an argument, so it carries its values.
    static func documentStartSource(
        key: String, handler: String, context: Int, nodeSpan: Int, frame: String
    ) throws -> String {
        let values = try DevToolsValue.object([
            "__key": .string(key), "__handler": .string(handler), "__context": .number(Double(context)),
            "__observes": .bool(true), "__nodeSpan": .number(Double(nodeSpan)), "__frame": .string(frame),
        ]).text()
        return
            "(function ({ __key, __handler, __context, __observes, __nodeSpan, __frame }) {\n\(source)\n})(\(values));"
    }

    // MARK: - Static Variables

    static let source = #"""
        if (globalThis[__key]) return true;
        const contextId = __context;
        const handles = new Map();
        const groups = new Map();
        const nodes = new Map();
        const nodeIds = new WeakMap();
        let nextHandle = 1;
        let nextNode = contextId * __nodeSpan + 1;
        let crossing = null;
        const history = [];
        const resources = [];
        const documentID = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
        let observingNetwork = false;
        let pressed = null;
        let hovered = null;

        addEventListener(__key, (event) => { crossing = event.composedPath()[0]; }, true);
        const post = (message) => {
          try { webkit.messageHandlers[__handler].postMessage(JSON.stringify(message)); } catch {}
        };
        const remember = (message) => {
          message.time = Date.now();
          history.push(message);
          if (history.length > 200) history.shift();
          post(message);
        };
        const failure = (message) => ({ __failure: message });
        const hold = (value, group) => {
          const objectId = `1.${contextId}.${nextHandle++}`;
          handles.set(objectId, value);
          if (group) {
            if (!groups.has(group)) groups.set(group, new Set());
            groups.get(group).add(objectId);
          }
          return objectId;
        };
        const subtypeOf = (value) => {
          if (Array.isArray(value)) return "array";
          if (value instanceof Node) return "node";
          if (value instanceof RegExp) return "regexp";
          if (value instanceof Date) return "date";
          if (value instanceof Map) return "map";
          if (value instanceof Set) return "set";
          if (value instanceof Error) return "error";
          if (value instanceof Promise) return "promise";
          return undefined;
        };
        const nodeLabel = (node) => {
          if (!(node instanceof Element)) return node.nodeName;
          const id = node.id ? `#${node.id}` : "";
          const classes = typeof node.className === "string" && node.className
            ? `.${node.className.trim().split(/\s+/).join(".")}` : "";
          return `${node.localName}${id}${classes}`;
        };
        const describeObject = (value, subtype) => {
          if (subtype === "array") return `Array(${value.length})`;
          if (subtype === "node") return nodeLabel(value);
          // WebKit's stack holds only the frames; Chromium's starts with the error.
          if (subtype === "error") return value.stack ? `${value}\n${value.stack}` : String(value);
          if (subtype === "regexp" || subtype === "date") return String(value);
          return value.constructor?.name ?? "Object";
        };
        const remote = (value, byValue, group) => {
          switch (typeof value) {
            case "undefined": return { type: "undefined" };
            case "string": return { type: "string", value };
            case "boolean": return { type: "boolean", value };
            case "number":
              if (Number.isFinite(value) && !Object.is(value, -0)) return { type: "number", value, description: String(value) };
              return { type: "number", unserializableValue: Object.is(value, -0) ? "-0" : String(value), description: String(value) };
            case "bigint": return { type: "bigint", unserializableValue: `${value}n`, description: `${value}n` };
            case "symbol": return { type: "symbol", description: String(value), objectId: hold(value, group) };
            case "function":
              return { type: "function", className: "Function", description: String(value).slice(0, 512), objectId: hold(value, group) };
          }
          if (value === null) return { type: "object", subtype: "null", value: null };
          const subtype = subtypeOf(value);
          const shape = { type: "object", className: value.constructor?.name ?? "Object", description: describeObject(value, subtype) };
          if (subtype) shape.subtype = subtype;
          if (byValue) {
            shape.value = JSON.parse(JSON.stringify(value) ?? "null");
            return shape;
          }
          shape.objectId = hold(value, group);
          return shape;
        };
        const exception = (error) => ({
          result: remote(error, false),
          exceptionDetails: {
            exceptionId: 1, text: "Uncaught", lineNumber: 0, columnNumber: 0,
            exception: remote(error, false), executionContextId: contextId,
          },
        });
        const resolveArgument = (argument) => {
          if (argument.objectId) {
            if (!handles.has(argument.objectId)) throw new Error("Could not find object with given id");
            return handles.get(argument.objectId);
          }
          if (argument.unserializableValue !== undefined) {
            const text = argument.unserializableValue;
            if (text === "NaN") return NaN;
            if (text === "Infinity") return Infinity;
            if (text === "-Infinity") return -Infinity;
            if (text === "-0") return -0;
            if (text.endsWith("n")) return BigInt(text.slice(0, -1));
          }
          return argument.value;
        };
        const settled = async (request, run) => {
          try {
            let value = run();
            if (request.awaitPromise) value = await value;
            return { result: remote(value, request.returnByValue, request.objectGroup) };
          } catch (error) {
            return exception(error);
          }
        };

        const idOf = (node) => {
          let id = nodeIds.get(node);
          if (!id) {
            id = nextNode++;
            nodeIds.set(node, id);
            nodes.set(id, node);
          }
          return id;
        };
        const nodeFor = (request) => {
          if (request.objectId) return handles.get(request.objectId);
          const id = request.backendNodeId ?? request.nodeId;
          return id === undefined ? undefined : nodes.get(id);
        };
        const nodeInfo = (node, depth, pierce) => {
          const info = {
            nodeId: idOf(node), backendNodeId: idOf(node), nodeType: node.nodeType, nodeName: node.nodeName,
            localName: node.localName ?? "", nodeValue: node.nodeValue ?? "", childNodeCount: node.childNodes.length,
          };
          if (node instanceof Element) info.attributes = [...node.attributes].flatMap((attribute) => [attribute.name, attribute.value]);
          if (node.nodeType === Node.DOCUMENT_NODE) Object.assign(info, { documentURL: node.URL, baseURL: node.baseURI, xmlVersion: "" });
          if (isFrame(node)) info.frameId = frameIdOf(node);
          if (depth !== 0) {
            info.children = [...node.childNodes].map((child) => nodeInfo(child, depth - 1, pierce));
            if (pierce && node.shadowRoot) {
              info.shadowRoots = [{ ...nodeInfo(node.shadowRoot, depth - 1, pierce), shadowRootType: node.shadowRoot.mode }];
            }
          }
          return info;
        };
        const frameIds = new WeakMap();
        const frameKeys = new Map();
        let nextFrame = 1;
        const newFrameId = () => `${__frame}.${nextFrame++}`;
        const frameIdOf = (element) => {
          let id = frameIds.get(element);
          if (!id) {
            id = newFrameId();
            frameIds.set(element, id);
          }
          return id;
        };
        const isFrame = (node) => node instanceof Element && (node.localName === "iframe" || node.localName === "frame");
        const frameURL = (element) => {
          // Only a same-origin frame opens its document to the page; a
          // cross-origin one's window can answer with a placeholder.
          const inside = element.contentDocument?.URL;
          if (inside && inside !== "about:blank") return inside;
          return element.src || (element.hasAttribute("srcdoc") ? "about:srcdoc" : "about:blank");
        };
        // A frame the page can't reach isn't its origin, whatever its address
        // says: a sandbox, or a blank frame sent somewhere else.
        const isOpaque = (element) => !element.contentDocument;
        const walkFrames = (root, found) => {
          for (const node of root.querySelectorAll("*")) {
            if (isFrame(node)) found.push(node);
            if (node.shadowRoot) walkFrames(node.shadowRoot, found);
          }
          return found;
        };
        const framesOf = (request) => {
          const navigated = new Map((request.navigated ?? []).map((frame) => [frame.url, frame.id]));
          const named = new Set();
          const frames = walkFrames(document, []).map((element) => {
            // The id a client heard for this address, the first time it's seen.
            const url = frameURL(element);
            const id = navigated.get(url);
            if (id && !named.has(id)) {
              named.add(id);
              frameIds.set(element, id);
            }
            return { id: frameIdOf(element), url, opaque: isOpaque(element) };
          });
          const known = new Set(frames.map((frame) => frame.url));
          // A closed shadow root hides its frames from every script, but their
          // loads still appear in the document's timeline, and the navigation
          // delegate hands over those that came later.
          const loaded = performance.getEntriesByType("resource")
            .filter((entry) => entry.initiatorType === "iframe" || entry.initiatorType === "frame")
            .map((entry) => entry.name);
          for (const url of [...loaded, ...navigated.keys()]) {
            if (known.has(url)) continue;
            known.add(url);
            if (!frameKeys.has(url)) frameKeys.set(url, navigated.get(url) ?? newFrameId());
            frames.push({ id: frameKeys.get(url), url });
          }
          return { frames };
        };
        const quad = (left, top, right, bottom) => [left, top, right, top, right, bottom, left, bottom];

        const roles = {
          A: "link", ARTICLE: "article", ASIDE: "complementary", BUTTON: "button", DETAILS: "group", DIALOG: "dialog",
          FOOTER: "contentinfo", FORM: "form", H1: "heading", H2: "heading", H3: "heading", H4: "heading", H5: "heading",
          H6: "heading", HEADER: "banner", HR: "separator", IFRAME: "Iframe", IMG: "image", LI: "listitem", MAIN: "main",
          NAV: "navigation", OL: "list", OPTION: "option", P: "paragraph", PROGRESS: "progressbar", SELECT: "combobox",
          SUMMARY: "button", TABLE: "table", TD: "cell", TEXTAREA: "textbox", TH: "columnheader", TR: "row", UL: "list",
        };
        const inputRoles = {
          button: "button", checkbox: "checkbox", color: "button", file: "button", image: "button", number: "spinbutton",
          radio: "radio", range: "slider", reset: "button", search: "searchbox", submit: "button",
        };
        const roleOf = (element) => {
          const explicit = element.getAttribute("role")?.trim().split(/\s+/)[0];
          if (explicit) return explicit;
          if (element.localName === "input") return element.type === "hidden" ? null : (inputRoles[element.type] ?? "textbox");
          if (element.localName === "a" && !element.hasAttribute("href")) return "generic";
          if (element.isContentEditable && element.parentElement?.isContentEditable !== true) return "textbox";
          return roles[element.tagName] ?? "generic";
        };
        const isShown = (element) => {
          if (element.getAttribute("aria-hidden") === "true" || element.hidden) return false;
          if (element.localName === "input" && element.type === "hidden") return false;
          const style = getComputedStyle(element);
          return style.display !== "none" && style.visibility !== "hidden" && style.visibility !== "collapse";
        };
        const textOf = (element) => (element.innerText ?? element.textContent ?? "").replace(/\s+/g, " ").trim();
        const labelledBy = (element) => (element.getAttribute("aria-labelledby") ?? "").split(/\s+/)
          .map((id) => id && document.getElementById(id)).filter(Boolean).map(textOf).join(" ").trim();
        const nameFromContent = new Set(["button", "cell", "checkbox", "columnheader", "heading", "link", "listitem", "menuitem",
          "option", "radio", "row", "switch", "tab", "treeitem"]);
        const nameOf = (element, role) => {
          const named = labelledBy(element) || element.getAttribute("aria-label")?.trim();
          if (named) return named;
          if (element.labels?.length) return [...element.labels].map(textOf).join(" ").trim();
          if (element.localName === "img") return element.alt ?? "";
          if (element.localName === "input" && ["button", "submit", "reset"].includes(element.type)) return element.value;
          if (element.placeholder) return element.placeholder;
          if (nameFromContent.has(role)) return textOf(element);
          return element.title ?? "";
        };
        const property = (name, type, value) => ({ name, value: { type, value } });
        const propertiesOf = (element, role) => {
          const properties = [];
          const level = /^H([1-6])$/.exec(element.tagName);
          if (level) properties.push(property("level", "integer", Number(level[1])));
          if (element === document.activeElement) properties.push(property("focused", "booleanOrUndefined", true));
          if (element.disabled || element.getAttribute("aria-disabled") === "true") properties.push(property("disabled", "boolean", true));
          if (element.required) properties.push(property("required", "boolean", true));
          if (role === "checkbox" || role === "radio" || role === "switch") {
            const checked = element.checked ?? element.getAttribute("aria-checked") === "true";
            properties.push(property("checked", "tristate", String(checked)));
          }
          const expanded = element.getAttribute("aria-expanded");
          if (expanded !== null) properties.push(property("expanded", "booleanOrUndefined", expanded === "true"));
          const selected = element.selected ?? element.getAttribute("aria-selected");
          if (selected === true || selected === "true") properties.push(property("selected", "booleanOrUndefined", true));
          return properties;
        };
        const valueOf = (element) => {
          if (element.localName === "input" && element.type === "password") return undefined;
          if (["input", "textarea", "select"].includes(element.localName) && typeof element.value === "string") return element.value;
          return undefined;
        };
        const accessibilityTree = () => {
          const results = [];
          const add = (node, parentId, shape) => {
            const nodeId = `ax-${idOf(node)}`;
            const entry = { nodeId, backendDOMNodeId: idOf(node), childIds: [], ignored: false, ...shape };
            if (parentId) entry.parentId = parentId;
            results.push(entry);
            return entry;
          };
          const walk = (node, parent) => {
            if (node.nodeType === Node.TEXT_NODE) {
              const text = node.nodeValue.replace(/\s+/g, " ").trim();
              if (text) parent.childIds.push(add(node, parent.nodeId, { role: { type: "role", value: "StaticText" }, name: { type: "computedString", value: text } }).nodeId);
              return;
            }
            if (!(node instanceof Element) || ["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE"].includes(node.tagName) || !isShown(node)) return;
            const role = roleOf(node);
            if (role === null) return;
            const name = nameOf(node, role);
            const shape = { role: { type: "role", value: role }, name: { type: "computedString", value: name }, properties: propertiesOf(node, role) };
            const value = valueOf(node);
            if (value !== undefined) shape.value = { type: "string", value };
            if (role === "generic" && !name) shape.ignored = true;
            const entry = add(node, parent.nodeId, shape);
            parent.childIds.push(entry.nodeId);
            for (const child of (node.shadowRoot ?? node).childNodes) walk(child, entry);
          };
          const root = add(document, null, {
            role: { type: "role", value: "RootWebArea" }, name: { type: "computedString", value: document.title },
            properties: [],
          });
          if (document.body) for (const child of document.body.childNodes) walk(child, root);
          return { nodes: results };
        };

        const buttons = { none: -1, left: 0, middle: 1, right: 2, back: 3, forward: 4 };
        const eventModifiers = (modifiers = 0) => ({
          altKey: !!(modifiers & 1), ctrlKey: !!(modifiers & 2), metaKey: !!(modifiers & 4), shiftKey: !!(modifiers & 8),
        });
        const elementAt = (x, y) => {
          let element = document.elementFromPoint(x, y);
          while (element?.shadowRoot) {
            const inner = element.shadowRoot.elementFromPoint(x, y);
            if (!inner || inner === element) break;
            element = inner;
          }
          return element;
        };
        const focusableAncestor = (element) => {
          for (let current = element; current; current = current.parentElement) {
            if (current.matches?.("a[href],button,input,select,textarea,[tabindex],[contenteditable]")) return current;
          }
          return null;
        };
        const pointer = (target, type, shape) => {
          const pointerType = type.replace("mouse", "pointer");
          if (type !== "click" && type !== "dblclick" && typeof PointerEvent === "function") {
            target.dispatchEvent(new PointerEvent(pointerType, { ...shape, pointerId: 1, pointerType: "mouse", isPrimary: true }));
          }
          return target.dispatchEvent(new MouseEvent(type, shape));
        };
        const dispatchMouse = (request) => {
          const { x, y } = request;
          const target = elementAt(x, y);
          if (!target) return {};
          const button = buttons[request.button ?? "left"] ?? 0;
          const shape = {
            bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y,
            screenX: x, screenY: y, button: Math.max(button, 0), buttons: request.buttons ?? 0,
            detail: request.clickCount ?? 0, ...eventModifiers(request.modifiers),
          };
          if (request.type === "mouseWheel") {
            const wheeled = target.dispatchEvent(new WheelEvent("wheel", { ...shape, deltaX: request.deltaX ?? 0, deltaY: request.deltaY ?? 0 }));
            if (wheeled) window.scrollBy(request.deltaX ?? 0, request.deltaY ?? 0);
            return {};
          }
          if (hovered !== target) {
            if (hovered?.isConnected) hovered.dispatchEvent(new MouseEvent("mouseout", { ...shape, relatedTarget: target }));
            target.dispatchEvent(new MouseEvent("mouseover", { ...shape, relatedTarget: hovered }));
            hovered = target;
          }
          if (request.type === "mouseMoved") {
            pointer(target, "mousemove", shape);
          } else if (request.type === "mousePressed") {
            pressed = target;
            if (pointer(target, "mousedown", shape)) {
              const focusable = focusableAncestor(target);
              if (focusable) focusable.focus({ preventScroll: true });
              else document.activeElement?.blur?.();
            }
          } else if (request.type === "mouseReleased") {
            pointer(target, "mouseup", shape);
            if (pressed && (pressed === target || pressed.contains(target) || target.contains(pressed))) {
              const clicked = pressed.contains(target) ? target : pressed;
              pointer(clicked, button === 2 ? "contextmenu" : "click", shape);
              if ((request.clickCount ?? 1) === 2) pointer(clicked, "dblclick", shape);
            }
            pressed = null;
          }
          return {};
        };
        const setNativeValue = (element, value) => {
          const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          Object.getOwnPropertyDescriptor(prototype, "value").set.call(element, value);
        };
        const activeField = () => {
          let element = document.activeElement;
          while (element?.shadowRoot?.activeElement) element = element.shadowRoot.activeElement;
          return element;
        };
        const insertText = (text) => {
          const element = activeField();
          if (!element || element === document.body) return false;
          if (document.execCommand("insertText", false, text)) return true;
          if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
            const start = element.selectionStart ?? element.value.length;
            const end = element.selectionEnd ?? start;
            setNativeValue(element, element.value.slice(0, start) + text + element.value.slice(end));
            element.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: text }));
            return true;
          }
          return false;
        };
        const keyCodes = { Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40, " ": 32 };
        const keyEvent = (type, request, codeOverride) => {
          const event = new KeyboardEvent(type, {
            key: request.key ?? "", code: request.code ?? "", location: request.location ?? 0, repeat: !!request.autoRepeat,
            bubbles: true, cancelable: true, composed: true, view: window, ...eventModifiers(request.modifiers),
          });
          const code = codeOverride ?? request.windowsVirtualKeyCode ?? keyCodes[request.key] ?? 0;
          Object.defineProperty(event, "keyCode", { value: code });
          Object.defineProperty(event, "which", { value: code });
          Object.defineProperty(event, "charCode", { value: type === "keypress" ? code : 0 });
          return (activeField() ?? document.body).dispatchEvent(event);
        };
        const submitImplicitly = (element) => {
          const form = element.form;
          if (!form) return;
          const submitter = form.querySelector("button:not([type]),button[type=submit],input[type=submit],input[type=image]");
          if (submitter) { submitter.click(); return; }
          const blocking = [...form.elements].filter((field) => field instanceof HTMLInputElement
            && !["button", "checkbox", "file", "hidden", "image", "radio", "reset", "submit"].includes(field.type));
          if (blocking.length <= 1) form.requestSubmit();
        };
        const moveFocus = (backward) => {
          const focusable = [...document.querySelectorAll("a[href],button,input,select,textarea,[tabindex]")]
            .filter((element) => !element.disabled && element.tabIndex >= 0 && isShown(element));
          if (!focusable.length) return;
          const step = backward ? -1 : 1;
          const next = (focusable.indexOf(document.activeElement) + step + focusable.length) % focusable.length;
          focusable[next].focus();
        };
        const keyDefault = (request) => {
          const element = activeField();
          if (request.key === "Tab") { moveFocus(!!(request.modifiers & 8)); return; }
          if (request.key === "Backspace") { document.execCommand("delete"); return; }
          if (request.key === "Delete") { document.execCommand("forwardDelete"); return; }
          if (request.key === "Enter") {
            if (element instanceof HTMLInputElement) submitImplicitly(element);
            else if (element instanceof HTMLTextAreaElement || element?.isContentEditable) insertText("\n");
            else if (element instanceof HTMLButtonElement || element instanceof HTMLAnchorElement) element.click();
            return;
          }
          if (request.text && request.text >= " ") insertText(request.text);
        };
        const dispatchKey = (request) => {
          if (request.type === "char") { insertText(request.text ?? ""); return {}; }
          if (request.type === "keyUp") { keyEvent("keyup", request); return {}; }
          const allowed = keyEvent("keydown", request);
          if (request.type === "rawKeyDown") {
            if (allowed && !request.text) keyDefault(request);
            return {};
          }
          if (!allowed) return {};
          if (request.text) keyEvent("keypress", request, request.text.charCodeAt(0));
          keyDefault(request);
          return {};
        };

        if (__observes) {
          post({ kind: "document" });
          for (const level of ["debug", "error", "info", "log", "warn", "dir", "table", "trace"]) {
            const original = console[level];
            console[level] = function (...values) {
              remember({ kind: "console", level, args: values.map((value) => { try { return remote(value, false); } catch { return { type: "undefined" }; } }) });
              return original.apply(this, values);
            };
          }
          addEventListener("error", (event) => remember({ kind: "exception", details: exception(event.error ?? event.message).exceptionDetails }));
          addEventListener("unhandledrejection", (event) => remember({ kind: "exception", details: exception(event.reason).exceptionDetails }));
          addEventListener("DOMContentLoaded", () => post({ kind: "domContent" }));
          try {
            new PerformanceObserver((list) => {
              for (const entry of list.getEntries()) {
                const report = { kind: "resource", url: entry.name, initiator: entry.initiatorType, status: entry.responseStatus ?? 0,
                  mimeType: entry.contentType ?? "", encodedBytes: entry.encodedBodySize ?? 0 };
                if (observingNetwork) post(report);
                else if (resources.length < 500) resources.push(report);
              }
            }).observe({ type: "resource", buffered: true });
          } catch {}
        }

        Object.defineProperty(globalThis, __key, { configurable: true, value: {
          documentID,
          settled,
          call: (request, run) => settled(request, () => {
            const receiver = request.objectId ? resolveArgument({ objectId: request.objectId }) : globalThis;
            return run.apply(receiver, (request.arguments ?? []).map(resolveArgument));
          }),
          properties: (request) => {
            if (!handles.has(request.objectId)) return failure("Could not find object with given id");
            const object = handles.get(request.objectId);
            const result = [];
            for (let current = object, own = true; current !== null && current !== undefined; current = Object.getPrototypeOf(current), own = false) {
              for (const name of Object.getOwnPropertyNames(current)) {
                const descriptor = Object.getOwnPropertyDescriptor(current, name);
                result.push({
                  name, isOwn: own, enumerable: !!descriptor.enumerable, configurable: !!descriptor.configurable,
                  writable: !!descriptor.writable,
                  ...("value" in descriptor ? { value: remote(descriptor.value, false, request.objectGroup) } : {}),
                });
              }
              if (request.ownProperties) break;
            }
            return { result };
          },
          history: () => ({ entries: history }),
          release: (request) => { handles.delete(request.objectId); return {}; },
          releaseGroup: (request) => {
            for (const objectId of groups.get(request.objectGroup) ?? []) handles.delete(objectId);
            groups.delete(request.objectGroup);
            return {};
          },
          binding: (request) => {
            globalThis[request.name] = (payload) => post({ kind: "binding", name: request.name, payload: String(payload) });
            return {};
          },
          observeNetwork: (request) => {
            observingNetwork = request.observing;
            if (observingNetwork) for (const report of resources.splice(0)) post(report);
            return {};
          },
          document: (request) => ({ root: nodeInfo(document, request.depth ?? 1, request.pierce) }),
          frames: framesOf,
          querySelector: (request) => {
            const found = nodeFor(request)?.querySelector(request.selector);
            return { nodeId: found ? idOf(found) : 0 };
          },
          querySelectorAll: (request) => ({ nodeIds: [...(nodeFor(request)?.querySelectorAll(request.selector) ?? [])].map(idOf) }),
          describeNode: (request) => {
            const node = nodeFor(request);
            return node ? { node: nodeInfo(node, request.depth ?? 0, request.pierce) } : failure("Could not find node with given id");
          },
          resolveNode: (request) => {
            const node = nodeFor(request);
            return node ? { object: remote(node, false, request.objectGroup) } : failure("No node with given id found");
          },
          expose: (request) => {
            const node = nodeFor(request);
            if (!node) return failure("No node with given id found");
            node.dispatchEvent(new Event(__key, { bubbles: true, composed: true }));
            return {};
          },
          adopt: (request) => {
            const node = crossing;
            crossing = null;
            return node ? { object: remote(node, false, request.objectGroup) } : failure("No node with given id found");
          },
          requestNode: (request) => {
            const node = handles.get(request.objectId);
            return node instanceof Node ? { nodeId: idOf(node) } : failure("Object id doesn't reference a Node");
          },
          boxModel: (request) => {
            const node = nodeFor(request);
            if (!(node instanceof Element)) return failure("Could not compute box model.");
            const box = node.getBoundingClientRect();
            const edges = quad(box.left, box.top, box.right, box.bottom);
            return { model: { content: edges, padding: edges, border: edges, margin: edges, width: box.width, height: box.height } };
          },
          contentQuads: (request) => {
            const node = nodeFor(request);
            if (!(node instanceof Element)) return failure("Could not compute content quads.");
            return { quads: [...node.getClientRects()].map((box) => quad(box.left, box.top, box.right, box.bottom)) };
          },
          focus: (request) => { nodeFor(request)?.focus?.(); return {}; },
          accessibilityTree,
          layoutMetrics: () => {
            const viewport = { pageX: scrollX, pageY: scrollY, clientWidth: innerWidth, clientHeight: innerHeight };
            const size = { x: 0, y: 0, width: document.documentElement.scrollWidth, height: document.documentElement.scrollHeight };
            return {
              layoutViewport: viewport, cssLayoutViewport: viewport, contentSize: size, cssContentSize: size,
              visualViewport: { offsetX: 0, offsetY: 0, ...viewport, scale: visualViewport?.scale ?? 1, zoom: 1 },
              cssVisualViewport: { offsetX: 0, offsetY: 0, ...viewport, scale: visualViewport?.scale ?? 1, zoom: 1 },
            };
          },
          mouse: dispatchMouse,
          key: dispatchKey,
          insertText: (request) => { insertText(request.text ?? ""); return {}; },
        } });
        return true;
        """#
}
