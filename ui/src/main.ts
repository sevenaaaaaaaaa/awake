import { createApp } from "vue";
import App from "./App.vue";
import "./styles.css";
import { initializeThemes } from "./themes";
import "./themes.css";

initializeThemes();

createApp(App).mount("#app");
