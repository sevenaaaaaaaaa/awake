import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

export default defineConfig({
  plugins: [vue()],
  // Tauri 用自定义协议服务静态资源，必须用相对路径
  base: "./",
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: { ignored: ["**/src-tauri/**", "**/target/**"] },
  },
  envPrefix: ["VITE_", "TAURI_"],
  build: {
    target: "safari15",
    minify: "esbuild",
    sourcemap: false,
  },
});
