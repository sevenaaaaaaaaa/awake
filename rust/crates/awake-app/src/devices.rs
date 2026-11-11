//! CoreAudio reports the output path; an analog headphone behind a DAC is user identified.
use crate::{experience, AppState};
use awake_core::chain::ListeningChain;
use serde::Serialize;
use tauri::State;
#[derive(Clone, Serialize)]
pub struct Identity {
    pub uid: String,
    pub transport: String,
}
#[cfg(target_os = "macos")]
pub fn identity() -> Result<Identity, String> {
    use core_foundation::{
        base::TCFType,
        string::{CFString, CFStringRef},
    };
    use std::{ffi::c_void, mem::size_of, ptr};
    #[repr(C)]
    struct Address {
        selector: u32,
        scope: u32,
        element: u32,
    }
    #[link(name = "CoreAudio", kind = "framework")]
    extern "C" {
        fn AudioObjectGetPropertyData(
            object: u32,
            address: *const Address,
            qualifier_size: u32,
            qualifier: *const c_void,
            size: *mut u32,
            data: *mut c_void,
        ) -> i32;
    }
    unsafe fn read<T: Copy>(object: u32, selector: [u8; 4], value: &mut T) -> Result<(), String> {
        let a = Address {
            selector: u32::from_be_bytes(selector),
            scope: u32::from_be_bytes(*b"glob"),
            element: 0,
        };
        let mut size = size_of::<T>() as u32;
        let status = AudioObjectGetPropertyData(
            object,
            &a,
            0,
            ptr::null(),
            &mut size,
            value as *mut T as *mut c_void,
        );
        if status != 0 || size != size_of::<T>() as u32 {
            Err(format!("无法读取音频设备属性（{status}）"))
        } else {
            Ok(())
        }
    }
    let mut device = 0u32;
    unsafe {
        read(1, *b"dOut", &mut device)?;
    }
    let mut uid: CFStringRef = ptr::null();
    unsafe {
        read(device, *b"uid ", &mut uid)?;
    }
    if uid.is_null() {
        return Err("设备 UID 不可用".into());
    }
    // CoreAudio CF properties follow the Create rule: the caller releases the returned reference.
    let uid = unsafe { CFString::wrap_under_create_rule(uid) }.to_string();
    let mut transport = 0u32;
    unsafe {
        read(device, *b"tran", &mut transport)?;
    }
    let transport = match transport.to_be_bytes() {
        [b'b', b'l', b'u', b'e'] | [b'b', b'l', b'e', b'a'] => "bluetooth",
        [b'u', b's', b'b', b' '] => "usb",
        [b'b', b'l', b't', b'n'] => "builtin",
        [b'h', b'd', b'm', b'i'] | [b'd', b'p', b' ', b' '] => "display",
        [b'v', b'i', b'r', b't'] => "virtual",
        _ => "unknown",
    };
    Ok(Identity {
        uid,
        transport: transport.into(),
    })
}
#[cfg(not(target_os = "macos"))]
pub fn identity() -> Result<Identity, String> {
    Err("设备识别仅支持 macOS".into())
}
#[derive(Serialize)]
pub struct Context {
    pub identity: Identity,
    pub chain: Option<ListeningChain>,
    pub sound_key: String,
}
fn migrate_legacy(state: &AppState, identity: &Identity) -> Result<(), String> {
    use cpal::traits::{DeviceTrait, HostTrait};
    let name = cpal::default_host()
        .default_output_device()
        .and_then(|d| d.name().ok());
    let Some(name) = name else {
        return Ok(());
    };
    let key = format!("device:{}:{}", identity.uid, identity.transport);
    let needs = {
        let taste = state.taste.lock();
        !taste.device_migrations.contains(&key)
            && (taste.sound_profiles.contains_key(&name)
                || taste.active_corrections.contains_key(&name))
    };
    if needs {
        experience::mutate_profile(&state.taste, &state.data_dir, |taste| {
            if let Some(gains) = taste.sound_profiles.get(&name).cloned() {
                taste.sound_profiles.entry(key.clone()).or_insert(gains);
            }
            if let Some(profile) = taste.active_corrections.get(&name).cloned() {
                taste
                    .active_corrections
                    .entry(key.clone())
                    .or_insert(profile);
            }
            taste.device_migrations.insert(key);
            Ok(())
        })?;
    }
    Ok(())
}
fn binding(identity: &Identity) -> String {
    serde_json::to_string(&(&identity.uid, &identity.transport)).unwrap()
}
pub fn context(state: &AppState) -> Result<Context, String> {
    let identity = identity()?;
    migrate_legacy(state, &identity)?;
    let taste = state.taste.lock();
    let chain = taste
        .active_chains
        .get(&binding(&identity))
        .and_then(|id| {
            taste.listening_chains.iter().find(|c| {
                &c.id == id && c.device_uid == identity.uid && c.transport == identity.transport
            })
        })
        .cloned();
    let sound_key = chain
        .as_ref()
        .map(|c| c.key())
        .unwrap_or_else(|| format!("device:{}:{}", identity.uid, identity.transport));
    Ok(Context {
        identity,
        chain,
        sound_key,
    })
}
#[tauri::command]
pub fn listening_context(state: State<'_, AppState>) -> Result<Context, String> {
    context(&state)
}
#[tauri::command]
pub fn save_listening_chain(
    mut chain: ListeningChain,
    state: State<'_, AppState>,
) -> Result<Context, String> {
    let device = identity()?;
    chain.device_uid = device.uid.clone();
    chain.transport = device.transport.clone();
    chain.validate()?;
    let existing = state
        .taste
        .lock()
        .listening_chains
        .iter()
        .any(|c| c.id == chain.id && c.same_acoustic_path(&chain));
    if !existing {
        chain.id = awake_core::models::new_id();
    }
    experience::mutate_profile(&state.taste, &state.data_dir, |taste| {
        taste.listening_chains.retain(|c| c.id != chain.id);
        if !existing && taste.listening_chains.len() >= 100 {
            return Err("最多保存 100 条聆听链路".into());
        }
        taste
            .active_chains
            .insert(binding(&device), chain.id.clone());
        taste.listening_chains.push(chain);
        Ok(())
    })?;
    context(&state)
}
#[tauri::command]
pub fn activate_listening_chain(
    id: Option<String>,
    state: State<'_, AppState>,
) -> Result<Context, String> {
    let device = identity()?;
    experience::mutate_profile(&state.taste, &state.data_dir, |taste| {
        if let Some(id) = id {
            if !taste.listening_chains.iter().any(|c| {
                c.id == id && c.device_uid == device.uid && c.transport == device.transport
            }) {
                return Err("这条配置不属于当前输出设备与传输方式".into());
            }
            taste.active_chains.insert(binding(&device), id);
        } else {
            taste.active_chains.remove(&binding(&device));
        }
        Ok(())
    })?;
    context(&state)
}
#[cfg(test)]
mod tests {
    #[test]
    #[ignore = "reads the real default CoreAudio output"]
    fn reads_coreaudio_uid_and_transport() {
        let d = super::identity().unwrap();
        assert!(!d.uid.is_empty());
        assert!(!d.transport.is_empty());
        println!("CoreAudio transport={}", d.transport);
    }
}
