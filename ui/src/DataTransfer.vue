<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import Icon from "./Icon.vue";
import {
  backupExport,
  backupExportFile,
  backupInspect,
  backupRestore,
  desktop,
  handoffScanPhones,
  handoffSendToPhone,
  handoffStart,
  handoffStatus,
  handoffStop,
  listenHandoffReceived,
  type BackupPreview,
  type BackupRestoreResult,
  type HandoffReceived,
  type HandoffStatus,
  type PhoneDevice,
  type PhoneHandoffResult,
} from "./bridge";
import { duration } from "./types";

// 数据与接力：加密备份（导出 / 预览 / 恢复）+ 手机 → 电脑接力接收。
// 命令与事件契约见 docs/backup-format.md 与 docs/handoff-protocol.md；
// 浏览器预览里不调用任何 Tauri 命令，只显示“需要桌面版”。
type Tab = "backup" | "handoff";

const props = defineProps<{ refresh: () => Promise<void> }>();
const emit = defineEmits<{
  close: [];
  toast: [message: string];
}>();

const tab = ref<Tab>("backup");
const firstField = ref<HTMLInputElement | null>(null);
const closeButton = ref<HTMLButtonElement | null>(null);

function readable(reason: unknown, action: string): string {
  const raw = String(reason instanceof Error ? reason.message : reason)
    .replace(/^Error:\s*/, "")
    .trim();
  if (!raw) return `${action}失败，请稍后重试。`;
  // Rust 端已经给出可读中文，直接展示。
  if (/[\u4e00-\u9fa5]/.test(raw)) return raw;
  if (/not found|unknown command|command .* not found/i.test(raw))
    return `桌面版还没有提供「${action}」能力，请更新到最新桌面版后再试。`;
  if (/password|decrypt|corrupt|invalid tag|aes|gcm/i.test(raw))
    return "密码错误或备份已损坏，请检查后重试。";
  if (/network|timed out|timeout|connect|dns|refused/i.test(raw))
    return `${action}失败：无法连接网络，请稍后重试。`;
  if (/json|format|parse|schema/i.test(raw))
    return `${action}失败：文件格式不正确，请选择 Awake 导出的 .awake-backup 文件。`;
  return `${action}失败：${raw}`;
}

function formatBytes(value: number): string {
  const bytes = Number(value);
  if (!Number.isFinite(bytes) || bytes <= 0) return "—";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function formatTime(ms: number): string {
  const value = Number(ms);
  if (!Number.isFinite(value) || value <= 0) return "时间未知";
  try {
    return new Intl.DateTimeFormat("zh-CN", {
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    }).format(new Date(value));
  } catch {
    return "时间未知";
  }
}

function clock(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return "";
  try {
    return new Intl.DateTimeFormat("zh-CN", {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    }).format(new Date(ms));
  } catch {
    return "";
  }
}

function stamp(): string {
  const now = new Date();
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(
    now.getHours(),
  )}${pad(now.getMinutes())}`;
}

function download(text: string, fileName: string) {
  const url = URL.createObjectURL(
    new Blob([text], { type: "application/json" }),
  );
  const link = document.createElement("a");
  link.href = url;
  link.download = fileName;
  link.rel = "noopener";
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/* ── 加密备份 ─────────────────────────────────────────── */

const exportPassword = ref("");
const exportConfirm = ref("");
const exportBusy = ref(false);
const exportError = ref("");
const exportDone = ref("");
const lastExport = ref("");

const exportTooShort = computed(
  () => exportPassword.value.length > 0 && exportPassword.value.length < 8,
);
const exportMismatch = computed(
  () =>
    exportConfirm.value.length > 0 &&
    exportPassword.value !== exportConfirm.value,
);
const exportReady = computed(
  () =>
    exportPassword.value.length >= 8 &&
    exportPassword.value === exportConfirm.value,
);

async function doExport() {
  if (!desktop || exportBusy.value) return;
  exportError.value = "";
  exportDone.value = "";
  if (exportPassword.value.length < 8) {
    exportError.value = "密码至少 8 个字符。";
    return;
  }
  if (exportPassword.value !== exportConfirm.value) {
    exportError.value = "两次输入的密码不一致。";
    return;
  }
  exportBusy.value = true;
  lastExport.value = "";
  try {
    let savedPath = "";
    if (desktop) {
      try {
        savedPath = await backupExportFile(exportPassword.value);
      } catch {
        savedPath = "";
      }
    }
    const text = await backupExport(exportPassword.value);
    if (typeof text !== "string" || !text.trim())
      throw new Error("备份内容是空的，请稍后重试");
    lastExport.value = text;
    const fileName = `awake-backup-${stamp()}.awake-backup`;
    const sizeLabel = formatBytes(new Blob([text]).size);
    if (savedPath) {
      exportDone.value = `已保存到 ${savedPath} · ${sizeLabel}。文件由密码加密，密码不会保存在任何地方。`;
      exportPassword.value = "";
      exportConfirm.value = "";
      emit("toast", "加密备份已保存到下载目录");
    } else {
      download(text, fileName);
      exportDone.value = `已生成 ${fileName} · ${sizeLabel}。文件由密码加密，密码不会保存在任何地方。`;
      exportPassword.value = "";
      exportConfirm.value = "";
      emit("toast", "加密备份已下载");
    }
  } catch (reason) {
    exportError.value = readable(reason, "导出加密备份");
  } finally {
    exportBusy.value = false;
  }
}

async function copyExport() {
  if (!lastExport.value) return;
  if (!navigator.clipboard) {
    emit("toast", "当前环境不能访问剪贴板，请改用浏览器预览下载");
    return;
  }
  try {
    await navigator.clipboard.writeText(lastExport.value);
    emit("toast", "备份文本已复制，可粘贴保存为 .awake-backup 文件");
  } catch {
    emit("toast", "复制失败，请改用浏览器预览下载");
  }
}

const backupText = ref("");
const backupFileInput = ref<HTMLInputElement | null>(null);
const backupFileName = ref("");
const backupBytes = ref(0);
const restorePassword = ref("");
const inspectBusy = ref(false);
const restoreBusy = ref(false);
const restoreError = ref("");
const preview = ref<BackupPreview | null>(null);
const restored = ref<BackupRestoreResult | null>(null);

const inspectReady = computed(
  () => !!backupText.value && restorePassword.value.length > 0,
);

async function readBackupFile(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = "";
  restoreError.value = "";
  preview.value = null;
  restored.value = null;
  if (!file) {
    backupText.value = "";
    backupFileName.value = "";
    backupBytes.value = 0;
    return;
  }
  if (file.size > 20 * 1024 * 1024) {
    backupText.value = "";
    backupFileName.value = "";
    backupBytes.value = 0;
    restoreError.value = "备份文件超过 20 MB，请确认选择的是 Awake 导出的备份。";
    return;
  }
  try {
    const text = await file.text();
    if (!text.trim()) {
      backupText.value = "";
      backupFileName.value = "";
      backupBytes.value = 0;
      restoreError.value = "这个文件是空的，请重新选择备份文件。";
      return;
    }
    backupText.value = text;
    backupFileName.value = file.name;
    backupBytes.value = file.size;
  } catch (reason) {
    backupText.value = "";
    backupFileName.value = "";
    backupBytes.value = 0;
    restoreError.value = readable(reason, "读取备份文件");
  }
}

async function doInspect() {
  if (!desktop || inspectBusy.value || restoreBusy.value) return;
  restoreError.value = "";
  restored.value = null;
  if (!backupText.value) {
    restoreError.value = "请先选择备份文件。";
    return;
  }
  if (!restorePassword.value) {
    restoreError.value = "请输入备份密码。";
    return;
  }
  inspectBusy.value = true;
  try {
    const result = await backupInspect(backupText.value, restorePassword.value);
    if (!result || typeof result !== "object")
      throw new Error("预览结果格式不正确");
    preview.value = result;
  } catch (reason) {
    preview.value = null;
    restoreError.value = readable(reason, "预览备份");
  } finally {
    inspectBusy.value = false;
  }
}

const crossPlatform = computed(
  () => !!preview.value && preview.value.schema !== "awake.backup.macos",
);

async function doRestore() {
  if (!desktop || restoreBusy.value || !preview.value) return;
  restoreError.value = "";
  restoreBusy.value = true;
  try {
    const result = await backupRestore(backupText.value, restorePassword.value);
    restored.value = result;
    preview.value = null;
    backupText.value = "";
    backupFileName.value = "";
    backupBytes.value = 0;
    restorePassword.value = "";
    if (backupFileInput.value) backupFileInput.value.value = "";
    emit("toast", "备份已恢复，正在刷新界面");
    await props.refresh();
  } catch (reason) {
    restoreError.value = readable(reason, "恢复备份");
  } finally {
    restoreBusy.value = false;
  }
}

/* ── 接力接收 ─────────────────────────────────────────── */

const handoff = ref<HandoffStatus | null>(null);
const handoffBusy = ref(false);
const handoffError = ref("");
const urlHint = ref("");
const received = ref<HandoffReceived | null>(null);
const receivedAt = ref(0);
const polledMessage = ref("");
const polledMessageAt = ref(0);

let pollTimer: number | undefined;
let pollInFlight = false;
let pollFailures = 0;
let pollError = false;
let unlisten: (() => void) | null = null;
let alive = true;
let eventListening = false;
let lastMessageSeen = "";

const manualHint = computed(() => {
  const status = handoff.value;
  if (!status?.active) return "";
  if (urlHint.value) return urlHint.value;
  return status.port ? `http://<电脑局域网 IP>:${status.port}` : "";
});

const handoffCode = computed(() => handoff.value?.code || "——————");

function startPolling() {
  stopPolling();
  if (!desktop) return;
  pollTimer = window.setInterval(() => void refreshStatus(), 2000);
}

function stopPolling() {
  if (pollTimer !== undefined) {
    window.clearInterval(pollTimer);
    pollTimer = undefined;
  }
}

async function refreshStatus(manual = false) {
  if (!desktop || pollInFlight) return;
  pollInFlight = true;
  try {
    const status = await handoffStatus();
    if (!alive) return;
    handoff.value = status;
    pollFailures = 0;
    if (pollError) {
      handoffError.value = "";
      pollError = false;
    }
    // 事件监听被 ACL 拦掉时的兜底：轮询 last_message 也能看到“已接力：曲名”。
    const message = String(status.last_message || "").trim();
    if (
      !eventListening &&
      status.active &&
      message &&
      message !== lastMessageSeen &&
      (message.startsWith("已接力") || message.startsWith("收到接力"))
    ) {
      lastMessageSeen = message;
      polledMessage.value = message;
      polledMessageAt.value = Date.now();
    }
  } catch (reason) {
    if (!alive) return;
    pollFailures += 1;
    // 后台轮询失败不打扰视线；只有用户主动操作或已在接收时才提示。
    if (manual || handoff.value?.active) {
      handoffError.value = readable(reason, "读取接力状态");
      pollError = true;
    }
    // 连续失败说明后端不可用，停止轮询避免每 2 秒刷一次错误。
    if (pollFailures >= 3) stopPolling();
  } finally {
    pollInFlight = false;
  }
}

async function doStart() {
  if (!desktop || handoffBusy.value) return;
  handoffError.value = "";
  pollError = false;
  handoffBusy.value = true;
  try {
    const session = await handoffStart();
    handoff.value = {
      active: true,
      code: session.code,
      port: session.port,
      name: session.name,
      last_message: "",
    };
    urlHint.value = session.url_hint || "";
    received.value = null;
    polledMessage.value = "";
    polledMessageAt.value = 0;
    lastMessageSeen = "";
    pollFailures = 0;
    startPolling();
    emit("toast", `接力接收已开启，配对码 ${session.code}`);
  } catch (reason) {
    handoffError.value = readable(reason, "开启接力接收");
  } finally {
    handoffBusy.value = false;
  }
}

async function doStop() {
  if (!desktop || handoffBusy.value) return;
  handoffError.value = "";
  pollError = false;
  handoffBusy.value = true;
  try {
    await handoffStop();
    handoff.value = {
      active: false,
      code: "",
      port: 0,
      name: "",
      last_message: "",
    };
    urlHint.value = "";
    received.value = null;
    polledMessage.value = "";
    polledMessageAt.value = 0;
    lastMessageSeen = "";
    emit("toast", "已停止接收接力");
  } catch (reason) {
    handoffError.value = readable(reason, "停止接力接收");
  } finally {
    handoffBusy.value = false;
  }
}

/* ── 电脑 → 手机接力 ──────────────────────────────────── */

const phones = ref<PhoneDevice[]>([]);
const phoneScanning = ref(false);
const phoneCode = ref("");
const phoneNote = ref("");
const phoneError = ref("");
const phoneResult = ref<PhoneHandoffResult | null>(null);
const phoneAddress = ref("");
const selectedPhone = computed(
  () => phones.value.find((phone) => phone.address === phoneAddress.value) ?? null,
);
const sendingToPhone = ref(false);

const phoneCodeReady = computed(
  () => phoneCode.value.replace(/\D/g, "").length === 6,
);

async function doScanPhones() {
  if (!desktop || phoneScanning.value) return;
  phoneError.value = "";
  phoneResult.value = null;
  phoneScanning.value = true;
  try {
    phones.value = await handoffScanPhones();
    if (phones.value.length === 0) {
      phoneNote.value =
        "没有找到手机。请在手机正在播放页点「接收接力」，确认两台设备在同一个 Wi-Fi。";
      phoneAddress.value = "";
    } else {
      if (!phones.value.some((phone) => phone.address === phoneAddress.value)) {
        phoneAddress.value = phones.value[0].address;
      }
      phoneNote.value = "";
    }
  } catch (reason) {
    phoneError.value = readable(reason, "搜索手机");
  } finally {
    phoneScanning.value = false;
  }
}

async function doSendToPhone() {
  const device = selectedPhone.value;
  if (!desktop || sendingToPhone.value) return;
  phoneError.value = "";
  phoneResult.value = null;
  if (!device) {
    phoneError.value = "先选一台手机，或在手机上开启「接收接力」后重新搜索。";
    return;
  }
  if (!phoneCodeReady.value) {
    phoneError.value = "配对码是手机上显示的 6 位数字。";
    return;
  }
  sendingToPhone.value = true;
  try {
    const result = await handoffSendToPhone(device, phoneCode.value);
    phoneResult.value = result;
    emit("toast", result.text);
    if (result.ok) {
      phoneCode.value = "";
      phoneNote.value = "已交接。想再发一次就重新输入手机上的配对码。";
    }
  } catch (reason) {
    phoneError.value = readable(reason, "接力到手机");
  } finally {
    sendingToPhone.value = false;
  }
}

async function copyHint() {
  const text = manualHint.value;
  if (!text) return;
  if (!navigator.clipboard) {
    emit("toast", "当前环境不能访问剪贴板，请手动复制");
    return;
  }
  try {
    await navigator.clipboard.writeText(text);
    emit("toast", "已复制手动连接地址");
  } catch {
    emit("toast", "当前环境不能访问剪贴板，请手动复制");
  }
}

/* ── 弹窗 ─────────────────────────────────────────────── */

const closing = computed(() => restoreBusy.value || handoffBusy.value);

function trapFocus(event: KeyboardEvent) {
  const nodes = Array.from(
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLElement>(
      "button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled)",
    ),
  ).filter((node) => node.tabIndex >= 0);
  const first = nodes[0];
  const last = nodes[nodes.length - 1];
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault();
    last?.focus();
  } else if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault();
    first?.focus();
  }
}

function requestClose() {
  if (closing.value) return;
  emit("close");
}

function selectTab(next: Tab, focus = false) {
  if (tab.value === next) return;
  tab.value = next;
  if (focus)
    void nextTick(() =>
      document
        .getElementById(next === "backup" ? "data-tab-backup" : "data-tab-handoff")
        ?.focus(),
    );
}

function onTabKeydown(event: KeyboardEvent, current: Tab) {
  if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
  event.preventDefault();
  selectTab(current === "backup" ? "handoff" : "backup", true);
}

watch(tab, (value) => {
  if (value !== "handoff" || !desktop) return;
  pollFailures = 0;
  void refreshStatus(true);
  startPolling();
});

onMounted(() => {
  if (desktop) {
    void refreshStatus(true);
    startPolling();
    void listenHandoffReceived((payload) => {
      if (!alive) return;
      received.value = payload;
      receivedAt.value = Date.now();
      polledMessage.value = "";
      polledMessageAt.value = 0;
      emit(
        "toast",
        payload.matched
          ? `已接力：${payload.title || "当前曲目"}`
          : `收到接力，但曲库里没有「${payload.title || "这首歌"}」`,
      );
      void refreshStatus();
    })
      .then((off) => {
        if (!off) return;
        eventListening = true;
        if (alive) unlisten = off;
        else off();
      })
      .catch(() => {
        // 事件监听需要 core:event 权限；不可用时退回 2s 轮询 last_message。
        eventListening = false;
      });
  }
  void nextTick(() => {
    // 浏览器预览里输入框是禁用的，这时把焦点放到关闭按钮，避免焦点留在弹窗外。
    const target =
      firstField.value && !firstField.value.disabled
        ? firstField.value
        : closeButton.value;
    target?.focus();
  });
});

onUnmounted(() => {
  alive = false;
  stopPolling();
  unlisten?.();
});
</script>

<template>
  <div class="modal-backdrop data-backdrop" @click.self="requestClose">
    <section
      class="modal data-modal"
      role="dialog"
      aria-modal="true"
      aria-label="数据与接力"
      @keydown.tab="trapFocus"
      @keydown.esc.stop="requestClose"
    >
      <div class="modal-heading">
        <div>
          <p class="eyebrow">YOUR DATA, YOUR RULES</p>
          <h2>数据与接力</h2>
        </div>
        <button
          ref="closeButton"
          class="icon-btn"
          aria-label="关闭数据与接力"
          :disabled="closing"
          @click="requestClose"
        >
          <Icon name="close" />
        </button>
      </div>

      <div v-if="!desktop" class="data-desktop-note" role="status">
        <Icon name="info" :size="18" />
        <div>
          <strong>需要桌面版</strong>
          <p class="muted">
            加密备份和手机 → 电脑接力需要 Awake 桌面版（Tauri）后端。浏览器预览只能查看界面，下面的按钮暂不可用。
          </p>
        </div>
      </div>

      <div class="data-tabs" role="tablist" aria-label="数据与接力">
        <button
          id="data-tab-backup"
          role="tab"
          aria-controls="data-panel-backup"
          :aria-selected="tab === 'backup'"
          :class="{ active: tab === 'backup' }"
          :tabindex="tab === 'backup' ? 0 : -1"
          @click="selectTab('backup')"
          @keydown="onTabKeydown($event, 'backup')"
        >
          <Icon name="shield" :size="15" />加密备份
        </button>
        <button
          id="data-tab-handoff"
          role="tab"
          aria-controls="data-panel-handoff"
          :aria-selected="tab === 'handoff'"
          :class="{ active: tab === 'handoff' }"
          :tabindex="tab === 'handoff' ? 0 : -1"
          @click="selectTab('handoff')"
          @keydown="onTabKeydown($event, 'handoff')"
        >
          <Icon name="cast" :size="15" />手机接力
        </button>
      </div>

      <section
        v-if="tab === 'backup'"
        id="data-panel-backup"
        class="data-panel"
        role="tabpanel"
        aria-labelledby="data-tab-backup"
      >
        <div class="data-section">
          <div class="data-section-head">
            <h3>导出加密备份</h3>
            <span class="data-badge">AES-256-GCM · PBKDF2</span>
          </div>
          <p class="muted data-copy">
            把曲库、歌单、收藏和听感设置写成一份加密文件。密码只在你的设备上使用，不会上传，也不会被保存；忘记密码无法找回。备份不包含钥匙串里的密码 / Token，也不包含音频文件。
          </p>
          <div class="data-grid">
            <div class="data-field">
              <label for="backup-password">设置密码（至少 8 位）</label>
              <input
                id="backup-password"
                ref="firstField"
                v-model="exportPassword"
                type="password"
                autocomplete="new-password"
                placeholder="至少 8 个字符"
                :disabled="!desktop || exportBusy"
              />
              <small v-if="exportTooShort" class="field-hint">
                还需要 {{ 8 - exportPassword.length }} 个字符。
              </small>
            </div>
            <div class="data-field">
              <label for="backup-confirm">再输一次密码</label>
              <input
                id="backup-confirm"
                v-model="exportConfirm"
                type="password"
                autocomplete="new-password"
                placeholder="确认密码"
                :disabled="!desktop || exportBusy"
                @keydown.enter.prevent="doExport"
              />
              <small v-if="exportMismatch" class="field-hint">
                两次输入的密码不一致。
              </small>
            </div>
          </div>
          <p v-if="exportError" class="job-error" role="alert">
            {{ exportError }}
          </p>
          <div class="data-actions">
            <button
              class="button primary"
              :disabled="!desktop || exportBusy || !exportReady"
              @click="doExport"
            >
              <span v-if="exportBusy" class="spinner" />
              <Icon v-else name="download" :size="15" />
              {{ exportBusy ? "正在生成…" : "生成并下载 .awake-backup" }}
            </button>
          </div>
          <p v-if="exportDone" class="data-success" role="status">
            <Icon name="check" :size="15" /><span>{{ exportDone }}</span>
          </p>
          <div v-if="lastExport" class="data-actions data-actions-ghost">
            <button class="text-button" @click="copyExport">
              <Icon name="copy" :size="13" />下载没有反应？复制备份文本
            </button>
          </div>
        </div>

        <div class="data-divider" />

        <div class="data-section">
          <div class="data-section-head">
            <h3>从备份恢复</h3>
            <span class="data-badge muted-badge">先预览，再恢复</span>
          </div>
          <p class="muted data-copy">
            选择之前导出的 .awake-backup 文件，输入密码先预览内容，确认后才会写入曲库。恢复前会自动保留一份安全副本。
          </p>
          <div class="data-field">
            <label for="backup-file">备份文件</label>
            <input
              id="backup-file"
              ref="backupFileInput"
              type="file"
              accept=".awake-backup,.json,application/json"
              :disabled="!desktop || restoreBusy"
              @change="readBackupFile"
            />
            <small v-if="backupFileName" class="muted">
              {{ backupFileName }} · {{ formatBytes(backupBytes) }}
            </small>
            <small v-else class="muted">
              文件只在本机读取与解密，不会上传。
            </small>
          </div>
          <div class="data-field">
            <label for="restore-password">备份密码</label>
            <input
              id="restore-password"
              v-model="restorePassword"
              type="password"
              autocomplete="current-password"
              placeholder="输入这份备份的密码"
              :disabled="!desktop || restoreBusy"
              @input="
                preview = null;
                restored = null;
              "
              @keydown.enter.prevent="doInspect"
            />
          </div>
          <div class="data-actions">
            <button
              class="button"
              :disabled="
                !desktop || inspectBusy || restoreBusy || !inspectReady
              "
              @click="doInspect"
            >
              <span v-if="inspectBusy" class="spinner" />
              <Icon v-else name="search" :size="15" />
              {{ inspectBusy ? "正在校验…" : "预览备份内容" }}
            </button>
          </div>

          <div v-if="preview" class="backup-preview">
            <div class="backup-preview-head">
              <strong>{{ preview.device || "未知设备" }}</strong>
              <span>{{ formatTime(preview.exported_at_ms) }}</span>
            </div>
            <div class="backup-stats">
              <div>
                <strong>{{ preview.tracks }}</strong><small>曲目</small>
              </div>
              <div>
                <strong>{{ preview.playlists }}</strong><small>歌单</small>
              </div>
              <div>
                <strong>{{ preview.favorites }}</strong><small>收藏</small>
              </div>
              <div>
                <strong>{{ formatBytes(preview.bytes) }}</strong
                ><small>大小</small>
              </div>
            </div>
            <p class="muted backup-schema">
              备份格式 {{ preview.schema }} · v{{ preview.version }}
            </p>
            <p v-if="crossPlatform" class="job-error" role="alert">
              这是其他平台（{{ preview.schema }}）的备份：跨平台不支持整体恢复，请在对应平台恢复，或在桌面端改用歌单导入。
            </p>
            <div class="backup-restore">
              <p class="muted">
                确认恢复会覆盖当前的曲库、歌单与收藏。备份不包含钥匙串里的密码 / Token，恢复后需要重新填写；跨平台不支持整体恢复。
              </p>
              <button
                class="button primary"
                :disabled="restoreBusy || crossPlatform"
                @click="doRestore"
              >
                <span v-if="restoreBusy" class="spinner" />
                <Icon v-else name="refresh" :size="15" />
                {{ restoreBusy ? "正在恢复…" : "确认恢复" }}
              </button>
            </div>
          </div>

          <p v-if="restoreError" class="job-error" role="alert">
            {{ restoreError }}
          </p>

          <div v-if="restored" class="data-success backup-restored" role="status">
            <Icon name="check" :size="16" />
            <div>
              <strong>
                已恢复 {{ restored.tracks }} 首曲目 ·
                {{ restored.playlists }} 份歌单 ·
                {{ restored.favorites }} 个收藏
              </strong>
              <small v-if="restored.safety_copy" class="muted">
                恢复前安全副本：{{ restored.safety_copy }}
              </small>
              <small class="muted">
                钥匙串里的密码 / Token 需要重新填写；音频文件不在备份内。
              </small>
            </div>
          </div>

          <p class="muted data-note">
            备份不包含钥匙串里的密码 / Token 与音频文件；跨平台不支持整体恢复（只支持歌单导入）。
          </p>
        </div>
      </section>

      <section
        v-else
        id="data-panel-handoff"
        class="data-panel"
        role="tabpanel"
        aria-labelledby="data-tab-handoff"
      >
        <div class="data-section">
          <div class="data-section-head">
            <h3>手机接力到这台电脑</h3>
            <span class="data-badge" :class="{ live: handoff?.active }">
              {{ handoff?.active ? "接收中" : "未开启" }}
            </span>
          </div>
          <p class="muted data-copy">
            在手机正在播放页选择「接力到电脑」，输入下方配对码。只在同一局域网内传输曲目信息与播放进度，不经过云端，也不发送音频文件或账号。
          </p>

          <div v-if="handoff?.active" class="handoff-card">
            <div class="handoff-code">
              <small>配对码</small>
              <strong>{{ handoffCode }}</strong>
            </div>
            <div class="handoff-meta">
              <div>
                <small>端口</small>
                <strong>{{ handoff.port || "—" }}</strong>
              </div>
              <div>
                <small>设备名</small>
                <strong>{{ handoff.name || "这台电脑" }}</strong>
              </div>
            </div>
          </div>

          <p v-if="manualHint" class="handoff-url">
            <span class="muted">手机端手动输入</span>
            <code>{{ manualHint }}</code>
            <button class="text-button" @click="copyHint">
              <Icon name="copy" :size="13" />复制
            </button>
          </p>

          <p v-if="handoff?.active" class="handoff-last muted">
            最近接收：{{
              handoff.last_message || "还没有收到手机发来的曲目"
            }}
          </p>

          <div
            v-if="!received && polledMessage"
            class="data-success handoff-received"
            role="status"
            aria-live="polite"
          >
            <Icon name="check" :size="16" />
            <div>
              <strong>{{ polledMessage }}</strong>
              <small class="muted">
                最近一次接收 · {{ clock(polledMessageAt) }}
              </small>
            </div>
          </div>

          <div
            v-if="received"
            class="data-success handoff-received"
            role="status"
            aria-live="polite"
          >
            <Icon :name="received.matched ? 'check' : 'info'" :size="16" />
            <div>
              <strong>
                {{ received.matched ? "已接力：" : "收到接力（未匹配）："
                }}{{ received.title || "当前曲目" }}
              </strong>
              <small class="muted">
                进度 {{ duration(received.position) }}
                <template v-if="received.matched">
                  · 电脑端已开始播放</template
                >
                <template v-else>
                  · 曲库里没有找到这首歌，可确认后手动播放</template
                >
                <template v-if="clock(receivedAt)">
                  · {{ clock(receivedAt) }}</template
                >
              </small>
            </div>
          </div>

          <div class="data-actions">
            <button
              v-if="!handoff?.active"
              class="button primary"
              :disabled="!desktop || handoffBusy"
              @click="doStart"
            >
              <span v-if="handoffBusy" class="spinner" />
              <Icon v-else name="cast" :size="15" />
              {{ handoffBusy ? "正在开启…" : "开始接收接力" }}
            </button>
            <button
              v-else
              class="button"
              :disabled="handoffBusy"
              @click="doStop"
            >
              <span v-if="handoffBusy" class="spinner" />
              <Icon v-else name="close" :size="15" />
              {{ handoffBusy ? "正在停止…" : "停止接收" }}
            </button>
          </div>

          <p v-if="handoffError" class="job-error" role="alert">
            {{ handoffError }}
          </p>

          <p class="muted data-note">
            配对码 10 分钟没有请求会自动过期；错码 5 次会换新码，界面会自动刷新。停止接收后端口与设备广播立即失效。
          </p>
        </div>

        <div class="data-section">
          <div class="data-section-head">
            <h3>这台电脑接力到手机</h3>
            <span class="data-badge" :class="{ live: phones.length > 0 }">
              {{ phones.length > 0 ? `${phones.length} 台可用` : "未搜索" }}
            </span>
          </div>
          <p class="muted data-copy">
            把电脑上正在播放的曲目和进度交给同一 Wi-Fi 的手机继续播放：先在手机正在播放页点「接收接力」，
            再在这里搜索并输入手机显示的 6 位配对码。只传曲目信息与进度，不传音频、账号或密码。
          </p>

          <div class="data-actions">
            <button
              class="button"
              :disabled="!desktop || phoneScanning"
              @click="doScanPhones"
            >
              <span v-if="phoneScanning" class="spinner" />
              <Icon v-else name="search" :size="15" />
              {{ phoneScanning ? "正在搜索…" : "搜索附近的手机" }}
            </button>
          </div>

          <div v-if="phones.length > 0" class="data-field">
            <label for="phone-target">选择手机</label>
            <select id="phone-target" v-model="phoneAddress">
              <option
                v-for="phone in phones"
                :key="phone.address"
                :value="phone.address"
              >
                {{ phone.name }} · {{ phone.address }}
              </option>
            </select>
          </div>

          <div class="data-field">
            <label for="phone-code">配对码</label>
            <input
              id="phone-code"
              v-model="phoneCode"
              inputmode="numeric"
              maxlength="6"
              autocomplete="one-time-code"
              placeholder="手机上显示的 6 位数字"
              @input="
                phoneCode = phoneCode.replace(/\D/g, '').slice(0, 6)
              "
            />
          </div>

          <div class="data-actions">
            <button
              class="button primary"
              :disabled="!desktop || sendingToPhone || !phoneCodeReady"
              @click="doSendToPhone"
            >
              <span v-if="sendingToPhone" class="spinner" />
              <Icon v-else name="cast" :size="15" />
              {{ sendingToPhone ? "正在接力…" : "接力到手机" }}
            </button>
          </div>

          <div
            v-if="phoneResult"
            class="data-success handoff-received"
            role="status"
            aria-live="polite"
          >
            <Icon :name="phoneResult.ok ? 'check' : 'info'" :size="16" />
            <div>
              <strong>{{ phoneResult.text }}</strong>
              <small class="muted">
                <template v-if="phoneResult.ok">
                  {{ phoneResult.title }} · 手机已开始播放
                </template>
                <template v-else>
                  可以确认手机曲库里是否有这首歌，或在手机上手动播放
                </template>
              </small>
            </div>
          </div>

          <p v-if="phoneNote" class="muted data-note">{{ phoneNote }}</p>

          <p v-if="phoneError" class="job-error" role="alert">{{ phoneError }}</p>

          <p class="muted data-note">
            手机需要停在「接收接力」页面：手机切到后台或锁屏后，接收会立即停止，端口与广播随之失效。
          </p>
        </div>
      </section>
    </section>
  </div>
</template>
