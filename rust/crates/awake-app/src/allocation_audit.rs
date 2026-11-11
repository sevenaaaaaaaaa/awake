//! Thread-local allocation audit used only by the deterministic callback regression.
use std::{
    alloc::{GlobalAlloc, Layout, System},
    cell::Cell,
};
thread_local! {static AUDIT:Cell<(bool,usize)>=const{Cell::new((false,0))};}
pub struct Audited;
fn count() {
    let _ = AUDIT.try_with(|v| {
        let (active, n) = v.get();
        if active {
            v.set((active, n + 1));
        }
    });
}
unsafe impl GlobalAlloc for Audited {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        count();
        System.alloc(layout)
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        count();
        System.alloc_zeroed(layout)
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        count();
        System.realloc(ptr, layout, size)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout)
    }
}
pub fn start() {
    AUDIT.with(|v| v.set((true, 0)));
}
pub fn finish() -> usize {
    AUDIT.with(|v| {
        let (_, n) = v.get();
        v.set((false, 0));
        n
    })
}
