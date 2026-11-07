// 阻止 Windows 下多开控制台窗口
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    awake_app_lib::run()
}
