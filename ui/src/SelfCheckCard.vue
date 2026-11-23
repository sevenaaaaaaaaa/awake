<script setup lang="ts">
/**
 * S2：设备内自检。
 *
 * 只锁纯函数。页面顶部必须写明「全绿不等于能听」——它测不到界面、手势、真实耳机。
 * 一条都不藏：红了就把期望与实际一起摊开，让人能判断是代码坏了还是断言写错了。
 */
import { ref } from "vue";
import { call, desktop } from "./bridge";

type Item = { id: string; name: string; ok: boolean; detail: string };
type Report = {
  version: string;
  checked_at: string;
  items: Item[];
  passed: number;
  total: number;
};

const report = ref<Report | null>(null);
const running = ref(false);
const fault = ref("");

async function run() {
  if (!desktop || running.value) return;
  running.value = true;
  fault.value = "";
  try {
    report.value = await call<Report>("self_check");
  } catch (error) {
    fault.value = String(error);
    report.value = null;
  } finally {
    running.value = false;
  }
}
</script>

<template>
  <section v-if="desktop" class="check-card">
    <div class="section-heading">
      <div>
        <h2>自检</h2>
        <p class="muted">
          只锁纯函数：曲线限幅、先验叠加、档案解析、依据判定、失效文案、同名不猜。
          全绿不等于产品可用——界面、手势、真实耳机它都测不到。
        </p>
      </div>
      <button class="button" :disabled="running" @click="run">
        {{ running ? "检查中…" : report ? "重新自检" : "运行自检" }}
      </button>
    </div>

    <p v-if="fault" class="check-fault">{{ fault }}</p>
    <p v-else-if="!report" class="muted">
      还没跑过。它会逐条报 PASS / FAIL，红的会说清期望与实际差多少。
    </p>

    <template v-else>
      <p class="summary" :class="{ bad: report.passed !== report.total }">
        {{ report.passed }} / {{ report.total }} 通过 · v{{ report.version }} ·
        {{ report.checked_at }}
      </p>
      <ul class="check-list">
        <li v-for="item in report.items" :key="item.id" :class="{ bad: !item.ok }">
          <span class="mark">{{ item.ok ? "PASS" : "FAIL" }}</span>
          <span class="name">{{ item.name }}</span>
          <span v-if="item.detail" class="detail">{{ item.detail }}</span>
        </li>
      </ul>
    </template>
  </section>
</template>

<style scoped>
.check-card {
  border: 1px solid var(--line);
  border-radius: 14px;
  background: var(--surface);
  padding: 4px 18px 18px;
  margin-top: 18px;
}
.check-fault {
  font-size: 12px;
  color: var(--text);
  border-left: 2px solid var(--dim);
  padding-left: 10px;
}
.summary {
  font-size: 12px;
  color: var(--muted);
  margin: 0 0 10px;
}
.summary.bad {
  color: var(--text);
}
.check-list {
  list-style: none;
  padding: 0;
  margin: 0;
  display: grid;
  gap: 8px;
}
.check-list li {
  display: grid;
  grid-template-columns: 46px 1fr;
  gap: 4px 10px;
  font-size: 12px;
  align-items: baseline;
}
.mark {
  font-family: var(--mono);
  font-size: 10px;
  letter-spacing: 0.06em;
  color: var(--dim);
}
.check-list li.bad .mark {
  color: var(--text);
}
.name {
  color: var(--text);
}
.detail {
  grid-column: 2;
  color: var(--dim);
  font-size: 11px;
  line-height: 1.5;
}
</style>
