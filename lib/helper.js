// Transport for the Swift accessibility helper: one JSON request in, one JSON
// result out, one process per call (~40 ms). The helper owns all AX/Quartz work;
// this file only handles spawning, arch fallback and error shaping.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, chmodSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const SOURCE = join(ROOT, "native", "axhelper.swift");
const PREBUILT = join(ROOT, "bin", "axhelper");
const CACHE = join(tmpdir(), "dsh-desktop-bg");

function cacheBinary() {
  return join(CACHE, "axhelper");
}

function compileTo(target) {
  mkdirSync(CACHE, { recursive: true });
  const res = spawnSync("/usr/bin/swiftc", ["-O", SOURCE, "-o", target], {
    encoding: "utf8",
    env: { ...process.env, TMPDIR: CACHE, CLANG_MODULE_CACHE_PATH: join(CACHE, "clang") },
    timeout: 120_000,
  });
  if (res.status !== 0) {
    throw new Error(`desktop-bg: swiftc could not build the helper\n${res.stderr || res.error?.message || ""}`);
  }
  chmodSync(target, 0o755);
  return target;
}

/**
 * Resolve a runnable helper. A prebuilt binary ships with the plugin; if the
 * host's architecture or OS cannot run it, build the shipped Swift source once
 * into the temp cache instead of failing the tool call.
 */
export function resolveHelper() {
  if (existsSync(PREBUILT) && helperRuns(PREBUILT)) return PREBUILT;
  const cached = cacheBinary();
  if (existsSync(cached) && helperRuns(cached)) return cached;
  return compileTo(cached);
}

function helperRuns(binary) {
  try {
    const probe = spawnSync(binary, ["{\"op\":\"probe\",\"pid\":-1}"], { encoding: "utf8", timeout: 15_000 });
    // a bad pid is a valid protocol answer: exit 1 with a JSON error body
    return typeof probe.stdout === "string" && probe.stdout.trim().startsWith("{");
  } catch {
    return false;
  }
}

/** Send one request to the helper and return its parsed JSON result. */
export function callHelper(request, { helper } = {}) {
  const binary = helper ?? resolveHelper();
  const res = spawnSync(binary, [JSON.stringify(request)], { encoding: "utf8", timeout: 30_000 });
  if (res.error) throw new Error(`desktop-bg: helper failed to start (${res.error.message})`);
  const line = (res.stdout || "").trim().split("\n").pop() ?? "";
  if (!line) throw new Error(`desktop-bg: helper returned nothing (stderr: ${(res.stderr || "").trim()})`);
  try {
    return JSON.parse(line);
  } catch {
    throw new Error(`desktop-bg: helper returned non-JSON output: ${line.slice(0, 400)}`);
  }
}

export const helperSearchPath = [CACHE, dirname(PREBUILT)].join(delimiter);
