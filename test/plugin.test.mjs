// Unit tests that need no Accessibility grants and touch no user app:
// they exercise the plugin wiring and the helper error paths.
import test from "node:test";
import assert from "node:assert/strict";
import { apply, tools, name } from "../lib/index.js";
import { callHelper, resolveHelper } from "../lib/helper.js";

test("plugin registers one tool per capability", () => {
  assert.equal(name, "desktop-bg");
  const registered = [];
  apply({ tools: { register: (t) => registered.push(t) } });
  assert.equal(registered.length, tools.length);
  assert.deepEqual(
    registered.map((t) => t.name).sort(),
    ["bg_click", "bg_key", "bg_press", "bg_press_at", "bg_probe", "bg_type", "bg_windows"],
  );
  for (const tool of registered) {
    assert.ok(tool.description.length > 40, `${tool.name} needs a real description`);
    assert.equal(typeof tool.execute, "function");
    // defineTool rejects a definition without an output spec (schema + render),
    // which is what broke the first install.
    assert.equal(typeof tool.output?.render, "function", `${tool.name} needs output.render`);
    assert.equal(tool.output?.schema?.type, "object", `${tool.name} needs an object output schema`);
  }
});

test("helper binary resolves and answers the protocol", () => {
  const helper = resolveHelper();
  const result = callHelper({ op: "probe", pid: process.pid }, { helper });
  assert.equal(result.ok, true);
  assert.equal(result.axTrusted, true, "Accessibility must be granted to the DSH process");
});

test("a dead pid is rejected before touching the helper", async () => {
  const typeTool = tools.find((t) => t.name === "bg_type");
  await assert.rejects(() => typeTool.execute({ pid: 999999, text: "x" }), /no running process/);
});

test("click outside the window is refused, not silently clamped", () => {
  const result = callHelper({ op: "click", pid: process.pid, x: 10, y: 10 });
  assert.equal(result.ok, false);
  assert.match(result.error, /no window|outside window/);
});
