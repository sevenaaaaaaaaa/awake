#!/usr/bin/env bash
# 真实源码 + 真实断言：把 LibraryImport.swift 与 harness 一起编译后在 macOS 上跑。
# 模拟器的 XCTest 服务在这台机器上起不来（DTServiceHubClient failed to bless service hub），
# 这条路径是纯逻辑唯一可重跑的验证；iOS XCTest 用例另在 AwakeTests.swift 里。
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)/library-import-harness"
swiftc -O -o "$out" ios/Awake/LibraryImport.swift ios/Awake/TabPaging.swift Tools/library_import_harness/main.swift
"$out"
