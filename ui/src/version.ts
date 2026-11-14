/**
 * 界面显示的版本号，只有这一个地方写。
 *
 * 两处会读它：侧栏底部的 "x.y.z / PERSONAL"，和启动时上报给后端的 `frontend_ready`。
 * 0.9.1 发版时这两处都还写着 0.9.0——侧栏显示错的版本，后端日志里也记着错的版本，
 * 而 `chore: bump version` 只改了 `Cargo.toml` 和 `package.json`。
 * `version.test.ts` 拿它和 `ui/package.json` 对比，发版漏改这里会直接红。
 */
export const APP_VERSION = "0.9.1";

/** 侧栏那一行的完整文案。 */
export const APP_VERSION_LINE = `${APP_VERSION} / PERSONAL`;
