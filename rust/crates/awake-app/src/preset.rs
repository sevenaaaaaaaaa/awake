//! AI 平台预置清单。
//!
//! 只预置「接口地址 + 模型名 + 说明」，不预置任何额度、不代注册、不含任何 key。
//! 用户仍然是自己注册、自己填 token——这里省掉的只是让他去翻文档抄 URL 的那一步。

use serde::Serialize;

/// 一个可一键填入的平台预设。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct AiPreset {
    /// 稳定 id，前端用它做选中状态，改动时不要复用到别的平台。
    pub id: &'static str,
    /// 显示名。
    pub label: &'static str,
    /// 用途：`curator` 选歌 / `music` 生成 / `both` 两者都能。
    pub kind: &'static str,
    pub endpoint: &'static str,
    pub model: &'static str,
    /// 给用户看的一句人话，说清免费额度是「平台给的」而不是我们给的。
    pub note: &'static str,
    pub docs: &'static str,
}

/// 预置清单。顺序有意为之：先国内可直连、再国外。
pub fn presets() -> Vec<AiPreset> {
    vec![
        AiPreset {
            id: "deepseek",
            label: "DeepSeek",
            kind: "curator",
            endpoint: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            note: "国内直连；注册后按平台当期政策有赠送额度",
            docs: "https://platform.deepseek.com/api_keys",
        },
        AiPreset {
            id: "moonshot",
            label: "Kimi / Moonshot",
            kind: "curator",
            endpoint: "https://api.moonshot.cn/v1",
            model: "moonshot-v1-8k",
            note: "国内直连；额度以平台控制台为准",
            docs: "https://platform.moonshot.cn/console/api-keys",
        },
        AiPreset {
            id: "zhipu",
            label: "智谱 GLM",
            kind: "curator",
            endpoint: "https://open.bigmodel.cn/api/paas/v4",
            model: "glm-4-flash",
            note: "flash 档长期免费，适合先跑通再换大模型",
            docs: "https://open.bigmodel.cn/usercenter/apikeys",
        },
        AiPreset {
            id: "dashscope",
            label: "阿里百炼 / 通义",
            kind: "curator",
            endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "qwen-plus",
            note: "OpenAI 兼容模式；新用户有试用额度",
            docs: "https://bailian.console.aliyun.com/",
        },
        AiPreset {
            id: "siliconflow",
            label: "硅基流动",
            kind: "both",
            endpoint: "https://api.siliconflow.cn/v1",
            model: "Qwen/Qwen2.5-7B-Instruct",
            note: "聚合多家开源模型；注册赠送额度",
            docs: "https://cloud.siliconflow.cn/account/ak",
        },
        AiPreset {
            id: "openai",
            label: "OpenAI",
            kind: "curator",
            endpoint: "https://api.openai.com/v1",
            model: "gpt-4o-mini",
            note: "需要能直连 api.openai.com；按量计费",
            docs: "https://platform.openai.com/api-keys",
        },
        AiPreset {
            id: "openrouter",
            label: "OpenRouter",
            kind: "curator",
            endpoint: "https://openrouter.ai/api/v1",
            model: "meta-llama/llama-3.3-70b-instruct:free",
            note: "有 :free 后缀的免费模型，额度与限速见平台",
            docs: "https://openrouter.ai/keys",
        },
        AiPreset {
            id: "groq",
            label: "Groq",
            kind: "curator",
            endpoint: "https://api.groq.com/openai/v1",
            model: "llama-3.3-70b-versatile",
            note: "有免费层，限速较严格；适合短请求",
            docs: "https://console.groq.com/keys",
        },
        AiPreset {
            id: "xai",
            label: "xAI Grok",
            kind: "curator",
            endpoint: "https://api.x.ai/v1",
            model: "grok-3-mini",
            note: "按量计费；需要能直连 api.x.ai",
            docs: "https://console.x.ai/",
        },
    ]
}

#[tauri::command]
pub fn ai_presets() -> Vec<AiPreset> {
    presets()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn ids_are_unique_and_stable_looking() {
        let list = presets();
        let mut seen = HashSet::new();
        for preset in &list {
            assert!(seen.insert(preset.id), "重复的预设 id: {}", preset.id);
            assert!(
                preset
                    .id
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'),
                "id 只允许小写字母数字和连字符: {}",
                preset.id
            );
        }
    }

    #[test]
    fn every_preset_is_https_and_complete() {
        for preset in presets() {
            assert!(
                preset.endpoint.starts_with("https://"),
                "{} 的地址必须走 https",
                preset.id
            );
            assert!(!preset.model.trim().is_empty(), "{} 缺模型名", preset.id);
            assert!(!preset.label.trim().is_empty(), "{} 缺显示名", preset.id);
            assert!(!preset.docs.starts_with("http://"), "{} 的文档链接应是 https", preset.id);
            assert!(
                matches!(preset.kind, "curator" | "music" | "both"),
                "{} 的 kind 不合法",
                preset.id
            );
        }
    }

    #[test]
    fn presets_never_carry_credentials() {
        for preset in presets() {
            let haystack = format!("{}{}{}", preset.endpoint, preset.model, preset.note);
            assert!(!haystack.contains("sk-"), "{} 里不该出现任何 key", preset.id);
            assert!(!haystack.to_lowercase().contains("api_key="), "{} 里不该带 key 参数", preset.id);
        }
    }
}
