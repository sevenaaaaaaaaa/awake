import test from "node:test";
import assert from "node:assert/strict";

import { parsePluginRegistry, pluginFileNameFromURL } from "./plugins.ts";

const sample = {
  plugins: [
    { name: "小秋音乐", url: "https://fastly.jsdelivr.net/gh/x/Music_Free/xiaoqiu.js", version: "0.3.0" },
    { name: "小蜗音乐", url: "https://fastly.jsdelivr.net/gh/x/Music_Free/xiaowo.js", version: "0.3.0" },
  ],
};

test("解析 {plugins} 形状的插件源", () => {
  const list = parsePluginRegistry(sample);
  assert.equal(list.length, 2);
  assert.deepEqual(list[0], {
    name: "小秋音乐",
    url: "https://fastly.jsdelivr.net/gh/x/Music_Free/xiaoqiu.js",
    version: "0.3.0",
  });
});

test("裸数组与 { data } 也认", () => {
  assert.equal(parsePluginRegistry(sample.plugins).length, 2);
  assert.equal(parsePluginRegistry({ data: sample.plugins }).length, 2);
});

test("丢点脏数据：缺名字、相对地址、非对象都跳过", () => {
  const list = parsePluginRegistry({
    plugins: [
      { name: "", url: "https://a/b.js" },
      { name: "x", url: "/relative.js" },
      null,
      { name: "ok", url: "https://a/ok.js" },
    ],
  });
  assert.equal(list.length, 1);
  assert.equal(list[0].name, "ok");
});

test("按地址去重，版本可缺省", () => {
  const list = parsePluginRegistry({
    plugins: [
      { name: "a", url: "https://a/b.js", version: "1" },
      { name: "a 副本", url: "https://a/b.js" },
    ],
  });
  assert.equal(list.length, 1);
  assert.equal(list[0].version, "1");
});

test("不是插件源就报错，不是返回空数组装没事", () => {
  assert.throws(() => parsePluginRegistry({ hello: 1 }));
  assert.throws(() => parsePluginRegistry(null));
  assert.throws(() => parsePluginRegistry({ plugins: [] }));
});

test("文件名从地址推，推不出给 plugin.js", () => {
  assert.equal(pluginFileNameFromURL("https://a/x/xiaoqiu.js"), "xiaoqiu.js");
  assert.equal(pluginFileNameFromURL("https://a/x/"), "plugin.js");
  assert.equal(pluginFileNameFromURL("not a url"), "plugin.js");
});

