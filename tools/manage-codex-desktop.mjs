#!/usr/bin/env node
import path from "node:path";
import os from "node:os";
import {
  inspectCodexDesktopPatch,
  patchCodexDesktop,
  restoreCodexDesktopPatch,
} from "./codex-desktop-patch.mjs";

const command = process.argv[2] || "inspect";
const bridgeHome = process.env.QWEN_CODEX_HOME || path.join(os.homedir(), ".qwen38-codex");
let result;

if (command === "inspect") {
  result = inspectCodexDesktopPatch({ bridgeHome });
} else if (command === "patch") {
  result = patchCodexDesktop({ bridgeHome });
} else if (command === "restore") {
  result = restoreCodexDesktopPatch({ bridgeHome });
} else {
  console.error("Usage: node manage-codex-desktop.mjs [inspect|patch|restore]");
  process.exit(2);
}

console.log(JSON.stringify(result, null, 2));
if (["error", "missing", "unsupported", "app-running", "target-not-found", "ambiguous"].includes(result.status)) {
  process.exit(1);
}
