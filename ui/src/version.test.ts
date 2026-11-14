import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { APP_VERSION, APP_VERSION_LINE } from "./version.ts";

const pkg = JSON.parse(
  readFileSync(new URL("../package.json", import.meta.url), "utf8"),
) as { version: string };

// 0.9.1 发版时 `chore: bump version` 只改了 package.json 与 Cargo.toml，
// 界面和后端日志里的版本还停在 0.9.0。这条对比就是那个漏口的补丁。
test("界面版本与 ui/package.json 一致，发版不能只改一处", () => {
  assert.equal(APP_VERSION, pkg.version);
});

test("版本文案格式：版本号 + PERSONAL", () => {
  assert.equal(APP_VERSION_LINE, `${pkg.version} / PERSONAL`);
  assert.match(APP_VERSION_LINE, /^\d+\.\d+\.\d+ \/ PERSONAL$/);
});
