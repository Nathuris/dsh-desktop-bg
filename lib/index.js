// desktop-bg — operate a macOS app whose window is covered by another window.
//
// Why this plugin exists: DSH's built-in computer-use tools escalate to
// `delivery_mode:"foreground"` for Electron/Chromium web content, because their
// pixel path has to hand real HID events to the WindowServer, which routes them
// to whatever window is on top. This plugin adds the two channels that are not
// routed that way:
//
//   * Accessibility element actions (AXPress / AXFocused) — independent of
//     window z-order. Chromium honours them for links, buttons and text fields.
//   * Quartz events posted to one pid (`CGEventPostToPid`) — the keyboard side
//     reaches the app's focused element with no focus steal at all.
//
// It does not pretend to fix what cannot be fixed: a plain pixel click into a
// Chromium canvas still needs either the real foreground or CDP, and `bg_click`
// says so instead of reporting a success it cannot prove.

import { callHelper } from "./helper.js";

let defineTool = (definition) => definition;
try {
  const tools = await import("@deepseek-ai/dsh-tools");
  if (typeof tools.defineTool === "function") defineTool = tools.defineTool;
} catch {
  // Host without the tools package (plain `node` / unit tests): keep raw defs.
}

/** defineTool requires an output spec (schema + render); results stay JSON text. */
function tool(definition) {
  return defineTool({
    ...definition,
    output: {
      schema: { type: "object", additionalProperties: true },
      render: (_args, result) => [{ type: "text", text: JSON.stringify(result, null, 2) }],
    },
  });
}

export const name = "desktop-bg";
export const inject = ["tools"];

const pidParam = {
  type: "integer",
  required: true,
  description: "Target process id (the app that owns the window you want to drive).",
};

function assertPid(pid) {
  try {
    process.kill(pid, 0);
  } catch {
    throw new Error(`desktop-bg: no running process with pid ${pid}`);
  }
}

function run(request) {
  assertPid(request.pid);
  const result = callHelper(request);
  if (result && result.ok === false && result.error) {
    return { ok: false, ...result, hint: hintFor(result.error) };
  }
  return result;
}

function hintFor(error) {
  if (/no AXTextField reachable|prune/i.test(error)) {
    return "The app is not exposing text fields while backgrounded. Bring it to the front once (or use DSH's foreground tools) so Chromium builds its tree, then retry in the background.";
  }
  if (/no element labelled/i.test(error)) {
    return "Labels come from the accessibility tree, which is thinner for a background window. Try bg_probe to see what is exposed, or use an exact label from a foreground get_window_state.";
  }
  if (/outside window/i.test(error)) {
    return "Coordinates are window-local POINTS, not screenshot pixels. Divide screenshot pixels by the capture scale (usually 2 on Retina, or width/points when the image was resized).";
  }
  return undefined;
}

const bgType = tool({
  name: "bg_type",
  description:
    "Type text into an app that is covered by other windows, without bringing it to the front. Focuses the target AXTextField through the Accessibility API and posts Unicode keystrokes straight to the process, so the frontmost app and the real keyboard focus are left untouched. Verified against Chromium/Electron apps (Douyin) with the window fully covered. The returned valueAfter is an AX read-back: it proves the control holds the text, not that a web renderer committed it — confirm visually when it matters.",
  parameters: {
    pid: pidParam,
    text: { type: "string", required: true, description: "Text to insert (Unicode is fine)." },
    match: {
      type: "string",
      description: "Optional substring to choose the field by its description, placeholder or title. Omit to use the topmost text field (usually the search box).",
    },
    clear: { type: "boolean", description: "Select-all + delete before typing, instead of appending." },
  },
  async execute(args) {
    return run({ op: "type", pid: args.pid, text: args.text, match: args.match, clear: args.clear === true });
  },
});

const bgPress = tool({
  name: "bg_press",
  description:
    "Press an accessibility element by its exact label in an app that is covered by other windows. Works on native AppKit controls and on Chromium links/buttons, because AX actions are not routed through the window server. Does nothing useful for text fields and custom-drawn canvases — use bg_type for text and DSH's foreground click for canvas regions.",
  parameters: {
    pid: pidParam,
    label: {
      type: "string",
      required: true,
      description: "Exact accessibility label (AXTitle, AXDescription or AXValue) of the element, e.g. \"搜索\" or \"评论\".",
    },
    role: { type: "string", description: "Optional AXRole filter such as AXButton or AXLink." },
  },
  async execute(args) {
    return run({ op: "press", pid: args.pid, label: args.label, role: args.role });
  },
});

const bgKey = tool({
  name: "bg_key",
  description:
    "Send one key (with optional modifiers) to a covered app's focused element, without stealing focus. Useful for escape/return/arrow navigation and shortcuts after bg_type. Delivery is dispatch-only: the driver cannot prove the app acted on it.",
  parameters: {
    pid: pidParam,
    key: {
      type: "string",
      required: true,
      description: "Key name: return, escape, tab, space, delete, up/down/left/right, home, end, pageup, pagedown, a-z, 0-9.",
    },
    modifiers: {
      type: "array",
      description: "Modifiers held for the keystroke: cmd, shift, alt/option, ctrl.",
      items: { type: "string", enum: ["cmd", "shift", "alt", "option", "ctrl", "control"] },
    },
  },
  async execute(args) {
    return run({ op: "key", pid: args.pid, key: args.key, modifiers: args.modifiers ?? [] });
  },
});

const bgClick = tool({
  name: "bg_click",
  description:
    "Post a mouse click to one specific process at window-local points. This bypasses the window server's hit-testing, so it can reach a covered window — but Chromium/Electron drops mouse events for a window that is not key, so it silently no-ops on web content. Use it for native apps, and fall back to DSH's delivery_mode:\"foreground\" click (or CDP) for web views. Reports dispatch only; verify the effect yourself.",
  parameters: {
    pid: pidParam,
    x: { type: "number", required: true, description: "Window-local X in POINTS (screenshot pixels divided by the capture scale)." },
    y: { type: "number", required: true, description: "Window-local Y in POINTS." },
    window: {
      type: "integer",
      description: "Which accessibility window to use when the process has several. Defaults to the largest.",
    },
  },
  async execute(args) {
    return run({ op: "click", pid: args.pid, x: args.x, y: args.y, window: args.window });
  },
});

const bgPressAt = tool({
  name: "bg_press_at",
  description:
    "Press whatever pressable accessibility element sits under a window-local point in a covered app — the background equivalent of a click for web content. Verified on Douyin: it opens a search result card and starts playback while another window stays in front. It is an accessibility action, not a real mouse event, so custom-drawn canvases and drag gestures still need the foreground path.",
  parameters: {
    pid: pidParam,
    x: { type: "number", required: true, description: "Window-local X in POINTS (screenshot pixels divided by the capture scale)." },
    y: { type: "number", required: true, description: "Window-local Y in POINTS." },
    window: {
      type: "integer",
      description: "Which accessibility window to use when the process has several. Defaults to the largest.",
    },
  },
  async execute(args) {
    return run({ op: "press_point", pid: args.pid, x: args.x, y: args.y, window: args.window });
  },
});

const bgWindows = tool({
  name: "bg_windows",
  description:
    "List the accessibility windows of a process with their screen origin and size in points, for a covered app. Use it to sanity-check coordinates and to learn which window is the real one before bg_click.",
  parameters: { pid: pidParam },
  async execute(args) {
    return run({ op: "windows", pid: args.pid });
  },
});

const bgProbe = tool({
  name: "bg_probe",
  description:
    "Diagnose how much of an app's accessibility tree is exposed while it is backgrounded: node count, role histogram, text fields and whether the Accessibility permission is active for this process. Run it when bg_type or bg_press cannot find a control.",
  parameters: { pid: pidParam },
  async execute(args) {
    return run({ op: "probe", pid: args.pid });
  },
});

export const tools = [bgType, bgPress, bgPressAt, bgKey, bgClick, bgWindows, bgProbe];

export function apply(ctx) {
  for (const tool of tools) ctx.tools.register(tool);
}
