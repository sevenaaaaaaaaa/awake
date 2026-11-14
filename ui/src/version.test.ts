import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { APP_VERSION, APP_VERSION_LINE } from "./version.ts";

const pkg = JSON.parse(
  readFileSync(new URL("../package.json", import.meta.url), "utf8"),
) as { version: string };

// 一次发版要同时改的「同一个版本号」有几个落点，这个文件把它们逐一钉住。
//
// 0.9.1 发版时 `chore: bump version` 只改了 rust/Cargo.toml 与 ui/package.json，
// 于是侧栏、`frontend_ready` 日志、`tauri.conf.json` 全都还停在 0.9.0。
// 每个落点各配一条断言，漏改哪一个都会直接红。
//
// 故意不纳入的落点，以及理由：
// - `rust/Cargo.lock`：由 cargo 生成，跟着 Cargo.toml 走，手改反而会错。
// - `ios/project.yml`：iOS 与桌面端可以各自版本（0.9.1 就没有 iOS 改动），
//   要求两者相等会让「桌面发版但 iOS 不动」变成不可能。
// - `Resources/AwakeInfo.plist`：旧 Swift 构建路径的模板，Rust 包不读它（由脚本内联生成）。
test("界面版本与 ui/package.json 一致，发版不能只改一处", () => {
  assert.equal(APP_VERSION, pkg.version);
});

test("版本文案格式：版本号 + PERSONAL", () => {
  assert.equal(APP_VERSION_LINE, `${pkg.version} / PERSONAL`);
  assert.match(APP_VERSION_LINE, /^\d+\.\d+\.\d+ \/ PERSONAL$/);
});

// `tauri build` / `tauri dev` 读这个文件决定包里的 CFBundleShortVersionString，
// 而 Tools/build_rust_app.sh 自己用 python 从 ui/package.json 生成 Info.plist。
// 两条构建路径的版本必须同源，否则「换个人构建」就换出一个版本号不同的包。
test("rust/crates/awake-app/tauri.conf.json 的版本与界面版本一致", () => {
  const conf = JSON.parse(
    readFileSync(
      new URL("../../rust/crates/awake-app/tauri.conf.json", import.meta.url),
      "utf8",
    ),
  ) as { version: string };
  assert.equal(conf.version, APP_VERSION);
});

// 后端二进制与 `frontend_ready` 上报的版本来自这里：各 crate 写的是 `version.workspace = true`。
// 逐行扫 `[workspace.package]` 段，避免被 `[workspace.dependencies]` 里的 version 干扰。
test("rust 工作区版本与界面版本一致", () => {
  const cargoToml = readFileSync(
    new URL("../../rust/Cargo.toml", import.meta.url),
    "utf8",
  );
  let inSection = false;
  let version: string | undefined;
  for (const raw of cargoToml.split("\n")) {
    const line = raw.trim();
    if (line.startsWith("[")) {
      inSection = line === "[workspace.package]";
      continue;
    }
    if (!inSection) continue;
    const m = line.match(/^version\s*=\s*"([^"]+)"/);
    if (m) {
      version = m[1];
      break;
    }
  }
  assert.ok(version, "rust/Cargo.toml 的 [workspace.package] 里找不到 version");
  assert.equal(version, APP_VERSION);
});
