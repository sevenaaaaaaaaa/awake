//! A listening configuration belongs to a physical output, headphone and connection path.
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListeningChain {
    pub id: String,
    pub device_uid: String,
    pub transport: String,
    pub name: String,
    pub headphone: String,
    pub connection: String,
    pub frontend: String,
    pub acoustic_mode: String,
    pub fit: String,
    pub codec_preference: String,
    pub reference_model: String,
    pub reference_evidence: String,
}
impl ListeningChain {
    pub fn same_acoustic_path(&self, other: &Self) -> bool {
        self.device_uid == other.device_uid
            && self.transport == other.transport
            && self.headphone == other.headphone
            && self.connection == other.connection
            && self.frontend == other.frontend
            && self.acoustic_mode == other.acoustic_mode
            && self.fit == other.fit
            && self.reference_model == other.reference_model
            && self.reference_evidence == other.reference_evidence
    }
    pub fn key(&self) -> String {
        format!("chain:{}", self.id)
    }
    pub fn validate(&self) -> Result<(), String> {
        if self.headphone.trim().is_empty()
            || self.name.trim().is_empty()
            || self.device_uid.is_empty()
        {
            return Err("请填写链路名称与耳机型号".into());
        }
        if ![
            "bluetooth",
            "wireless_24",
            "usb",
            "analog",
            "builtin",
            "unknown",
        ]
        .contains(&self.connection.as_str())
        {
            return Err("未知连接模式".into());
        }
        if [
            &self.name,
            &self.headphone,
            &self.frontend,
            &self.acoustic_mode,
            &self.fit,
            &self.codec_preference,
            &self.reference_model,
            &self.reference_evidence,
        ]
        .iter()
        .any(|s| s.chars().count() > 500)
        {
            return Err("链路字段过长".into());
        }
        if !self.reference_model.is_empty() && self.reference_evidence.trim().is_empty() {
            return Err("使用参考型号时请记录同单元、调音或其他判断依据".into());
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chains_remain_independent_on_the_same_dac_and_require_reference_evidence() {
        let mut a = ListeningChain {
            id: "a".into(),
            device_uid: "dac".into(),
            transport: "usb".into(),
            name: "桌面".into(),
            headphone: "HD 600".into(),
            connection: "analog".into(),
            frontend: "DAC".into(),
            acoustic_mode: "passive".into(),
            fit: "stock".into(),
            codec_preference: "system".into(),
            reference_model: String::new(),
            reference_evidence: String::new(),
        };
        a.validate().unwrap();
        let mut b = a.clone();
        b.name = "renamed".into();
        assert!(a.same_acoustic_path(&b));
        b.id = "b".into();
        b.connection = "wireless_24".into();
        assert!(!a.same_acoustic_path(&b));
        assert_ne!(a.key(), b.key());
        a.reference_model = "other".into();
        assert!(a.validate().is_err());
    }
}
