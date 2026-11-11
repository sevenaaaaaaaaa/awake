<script setup lang="ts">
import { computed, reactive, ref, watch } from "vue";
import { call, desktop } from "./bridge";
import type { ListeningContext, ListeningChain, Services } from "./types";
const props = defineProps<{
  context: ListeningContext | null;
  chains: ListeningChain[];
  services: Services;
  device: string;
  outputRate: number;
}>();
const emit = defineEmits<{ changed: [] }>();
const blank = (): ListeningChain => ({
  id: "",
  device_uid: "",
  transport: "",
  name: "",
  headphone: "",
  connection: "unknown",
  frontend: "",
  acoustic_mode: "unknown",
  fit: "原装耳套 / 耳垫",
  codec_preference: "system",
  reference_model: "",
  reference_evidence: "",
});
const draft = reactive(blank()),
  error = ref(""),
  busy = ref(false),
  notice = ref(""),
  editing = ref(false);
interface Candidate {
  name: string;
  path: string;
  attribution: string;
  source_url: string;
  mode: string;
  note: string;
}
interface Preview {
  candidate: Candidate;
  text: string;
  target: string;
  preamp: number;
  filters: unknown[];
}
const candidates = ref<Candidate[]>([]),
  preview = ref<Preview | null>(null),
  query = ref(""),
  searched = ref(false),
  aiAdvice = ref<{ path: string; reason: string; codec_advice: string } | null>(
    null,
  ),
  reference = ref(false);
const presets = [
  "Apple AirPods Pro 3",
  "Apple AirPods Pro 2",
  "Apple AirPods Max 2",
  "Samsung Galaxy Buds2 Pro",
];
const connections: Record<string, string> = {
  bluetooth: "蓝牙",
  wireless_24: "无线 2.4GHz 接收器",
  usb: "USB 数字音频",
  analog: "有线 · 模拟耳机",
  builtin: "内置输出",
  unknown: "待确认",
};
const acoustic: Record<string, string> = {
  unknown: "状态待确认",
  anc_on: "ANC 开启",
  anc_off: "ANC 关闭",
  transparency: "通透模式",
  passive: "关机 / 被动模式",
  open: "开放式佩戴",
};
const normalized = (s: string) =>
  s.toLowerCase().replace(/[^a-z0-9\u4e00-\u9fff]/g, "");
const compatiblePreview = computed(() => {
  if (!preview.value || !props.context?.chain) return false;
  const expected =
    props.context.chain.reference_model || props.context.chain.headphone;
  const base = preview.value.candidate.name.split(" (")[0];
  return normalized(base).endsWith(normalized(expected));
});
const matchingChains = computed(() =>
  props.chains.filter(
    (c) =>
      c.device_uid === props.context?.identity.uid &&
      c.transport === props.context?.identity.transport,
  ),
);
const transportName = computed(
  () =>
    ({
      bluetooth: "蓝牙",
      usb: "USB",
      builtin: "内置",
      display: "显示器 / HDMI",
      virtual: "虚拟声卡",
      unknown: "未知",
    })[props.context?.identity.transport || "unknown"],
);
watch(
  () => `${props.context?.sound_key || ""}\u0000${props.device}`,
  () => {
    const context = props.context;
    Object.assign(
      draft,
      context?.chain
        ? { ...context.chain }
        : {
            ...blank(),
            headphone: props.device,
            name: props.device + " · 默认",
            connection:
              context?.identity.transport === "bluetooth"
                ? "bluetooth"
                : context?.identity.transport === "usb"
                  ? "usb"
                  : "unknown",
          },
    );
    query.value =
      context?.chain?.reference_model ||
      context?.chain?.headphone ||
      props.device;
    reference.value = !!context?.chain?.reference_model;
    preview.value = null;
    aiAdvice.value = null;
    editing.value = false;
  },
  { immediate: true },
);
async function run(f: () => Promise<void>) {
  busy.value = true;
  error.value = "";
  try {
    await f();
  } catch (e) {
    error.value = String(e);
  } finally {
    busy.value = false;
  }
}
async function save(copy = false) {
  await run(async () => {
    await call("save_listening_chain", {
      chain: {
        ...draft,
        id: copy ? "" : draft.id,
        reference_model: reference.value ? draft.reference_model : "",
        reference_evidence: reference.value ? draft.reference_evidence : "",
      },
    });
    emit("changed");
    editing.value = false;
    notice.value = "已保存此耳机、连接方式与前端的独立听感配置";
  });
}
async function activate(id: string) {
  await run(async () => {
    await call("activate_listening_chain", { id: id || null });
    emit("changed");
  });
}
async function search(refresh = false) {
  await run(async () => {
    preview.value = null;
    aiAdvice.value = null;
    const result = await call<{
      candidates: Candidate[];
      warning: string | null;
    }>("search_headphones", {
      query: query.value,
      mode: draft.acoustic_mode,
      refresh,
    });
    candidates.value = result.candidates;
    notice.value = result.warning || "";
    searched.value = true;
  });
}
async function inspect(path: string) {
  await run(async () => {
    preview.value = await call<Preview>("preview_headphone_eq", { path });
  });
}
async function aiMatch() {
  await run(async () => {
    aiAdvice.value = await call("ai_match_headphone", {
      paths: candidates.value.map((c) => c.path),
    });
  });
}
async function apply() {
  if (!preview.value || !props.context?.chain || !compatiblePreview.value)
    return;
  const p = preview.value,
    contextKey = props.context.sound_key;
  await run(async () => {
    await call("import_headphone_profile", {
      name:
        p.candidate.name +
        (props.context?.chain?.reference_model ? " · 参考试听" : ""),
      measurementSource:
        p.candidate.attribution +
        " · " +
        p.candidate.source_url +
        (props.context?.chain?.reference_model
          ? " · 参考依据：" + props.context.chain.reference_evidence
          : ""),
      target: p.target,
      text: p.text,
      device: contextKey,
    });
    emit("changed");
    notice.value = "参数校正已应用到当前链路，重新连接后自动恢复";
  });
}
</script>
<template>
  <section class="eq-card chain-panel">
    <div class="section-heading">
      <div>
        <h2>你的聆听链路</h2>
        <p>
          {{ device }} · 系统识别：{{ transportName }} · PCM 输出
          {{
            outputRate ? (outputRate / 1000).toFixed(1) + " kHz" : "待播放"
          }}
          · 无线编码：系统未公开
        </p>
      </div>
      <button class="button" @click="editing = !editing">
        {{ editing ? "收起配置" : "配置耳机与连接" }}
      </button>
    </div>
    <label class="field-label"
      >当前配置<select
        :value="context?.chain?.id || ''"
        :disabled="!desktop || busy"
        @change="activate(($event.target as HTMLSelectElement).value)"
      >
        <option value="">仅使用设备默认配置</option>
        <option
          v-for="chain in matchingChains"
          :key="chain.id"
          :value="chain.id"
        >
          {{ chain.name }} · {{ connections[chain.connection] }}
        </option>
      </select></label
    >
    <p v-if="context?.chain" class="chain-summary">
      {{ context.chain.headphone }} → {{ connections[context.chain.connection]
      }}<span v-if="context.chain.frontend">
        → {{ context.chain.frontend }}</span
      >
      · {{ acoustic[context.chain.acoustic_mode] }} · {{ context.chain.fit }}
    </p>
    <p class="muted">
      USB 接收器可能是 2.4GHz
      无线，也可能是小尾巴；模拟耳机型号由你绑定。蓝牙编码和无线协议由系统或接收器协商，选择偏好不会强制切换编码。
    </p>
    <form v-if="editing" class="chain-form" @submit.prevent="save(false)">
      <label
        >配置名称<input
          v-model="draft.name"
          required
          placeholder="例如 Max 2 · 蓝牙 · 降噪" /></label
      ><label
        >耳机型号<input
          v-model="draft.headphone"
          list="headphone-models"
          required /><datalist id="headphone-models">
          <option v-for="p in presets" :key="p" :value="p" /></datalist
      ></label>
      <label
        >实际连接方式<select v-model="draft.connection">
          <option v-for="(name, id) in connections" :value="id" :key="id">
            {{ name }}
          </option>
        </select></label
      ><label
        >前端 / 小尾巴 / 接收器<input
          v-model="draft.frontend"
          placeholder="可选：DAC、声卡或无线接收器型号"
      /></label>
      <label
        >声学状态<select v-model="draft.acoustic_mode">
          <option v-for="(name, id) in acoustic" :key="id" :value="id">
            {{ name }}
          </option>
        </select></label
      ><label
        >耳套 / 耳垫 / 佩戴<input
          v-model="draft.fit"
          placeholder="开放式可记录佩戴位置"
      /></label>
      <label
        >编码策略<select v-model="draft.codec_preference">
          <option value="system">系统自动协商</option>
          <option value="quality">音质优先（建议）</option>
          <option value="latency">低延迟优先（建议）</option>
          <option value="wired_pcm">有线 PCM（需实际有线连接）</option>
        </select></label
      >
      <label class="check-line"
        ><input
          type="checkbox"
          v-model="reference"
        />使用其他型号作为参考</label
      >
      <template v-if="reference"
        ><label
          >参考型号<input
            v-model="draft.reference_model"
            required
            placeholder="明确填写参考耳机的完整型号" /></label
        ><label
          >参考依据<input
            v-model="draft.reference_evidence"
            required
            placeholder="记录出处；同单元 / 芯片不保证同调音"
        /></label>
        <p class="muted">
          参考校正属于实验试听，不作为本型号实测。耳腔、耳垫、DSP 和主动 /
          被动模式都可能改变频响。
        </p></template
      >
      <div class="theme-actions">
        <button class="button primary" :disabled="!desktop || busy">
          保存此配置</button
        ><button
          v-if="draft.id"
          type="button"
          class="button"
          :disabled="busy"
          @click="save(true)"
        >
          另存为新链路
        </button>
      </div>
    </form>
  </section>
  <section class="eq-card">
    <div class="section-heading">
      <div>
        <h2>找到对应耳机的测量 EQ</h2>
        <p>
          按型号查找 AutoEq
          与已收录的社区测量拟合，保留测量者、模式与来源；下载后先预览，再绑定到当前链路。
        </p>
      </div>
    </div>
    <form class="measurement-search" @submit.prevent="search()">
      <input
        v-model="query"
        aria-label="查询耳机型号"
        placeholder="完整型号，例如 Apple AirPods Pro 2"
      /><button class="button primary" :disabled="!desktop || busy">
        {{ busy ? "正在处理…" : "查找参数" }}</button
      ><button
        type="button"
        class="button"
        :disabled="!desktop || busy"
        @click="search(true)"
      >
        更新目录
      </button>
    </form>
    <div class="preset-row">
      <button v-for="p in presets" :key="p" @click="query = p">{{ p }}</button>
    </div>
    <p v-if="searched && !candidates.length" class="list-empty">
      当前测量库未找到此型号。可以导入其他社区的参数文件，或明确指定参考型号及依据；不会自动用上一代替代。
    </p>
    <div v-if="candidates.length" class="theme-actions">
      <button
        class="button"
        :disabled="busy || !services.curator || !context?.chain"
        @click="aiMatch"
      >
        AI 比较测量与连接模式</button
      ><small class="muted"
        >仅主动点击时发送型号、连接、耳套、参考依据和候选元数据；不发送设备
        UID、音频或来源凭据。</small
      >
    </div>
    <div v-if="aiAdvice" class="info-panel">
      <div>
        <strong>AI 候选建议 · 仍需核对测量条件</strong>
        <p>{{ aiAdvice.reason }}</p>
        <p>{{ aiAdvice.codec_advice }}</p>
      </div>
    </div>
    <div class="measurement-results">
      <article
        v-for="candidate in candidates"
        :key="candidate.path"
        class="measurement-row"
        :class="{ recommended: aiAdvice?.path === candidate.path }"
      >
        <div>
          <strong>{{ candidate.name }}</strong
          ><small>{{ candidate.attribution }} · {{ candidate.mode }}</small
          ><small>{{ candidate.note }}</small
          ><span class="measurement-url">{{ candidate.source_url }}</span>
        </div>
        <button
          class="button"
          :disabled="busy"
          @click="inspect(candidate.path)"
        >
          预览参数
        </button>
      </article>
    </div>
    <div v-if="preview" class="measurement-preview">
      <h3>{{ preview.candidate.name }}</h3>
      <p>{{ preview.candidate.note }}</p>
      <p>
        {{ preview.filters.length }} 个滤波器 · 原始前级 {{ preview.preamp }} dB
        · {{ preview.target }}
      </p>
      <pre>{{ preview.text }}</pre>
      <p v-if="context?.chain?.reference_model" class="job-error">
        参考试听：{{ context.chain.reference_model }}，不能视为
        {{ context.chain.headphone }} 的实测校正。
      </p>
      <button
        class="button primary"
        :disabled="!compatiblePreview || busy"
        @click="apply"
      >
        应用到当前聆听链路</button
      ><small v-if="!context?.chain" class="muted"
        >请先在上方保存耳机与连接配置。</small
      >
      <p v-else-if="!compatiblePreview" class="job-error">
        候选与当前型号不同。若要参考试听，请先在链路里填写参考型号与依据。
      </p>
    </div>
    <p v-if="!desktop" class="muted">测量库与设备识别请在桌面版使用。</p>
    <p v-if="error" class="job-error" role="alert">{{ error }}</p>
    <p v-if="notice" role="status">{{ notice }}</p>
  </section>
</template>
