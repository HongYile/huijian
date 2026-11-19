//! C 接口（Swift、Windows 调用）与 JNI 接口（安卓）。只有一个入口：传入请求 JSON，返回结果 JSON（见 api.rs）。
//! 内部任何 panic 都被拦下来变成错误结果，不会让 App 崩溃。
use crate::api;
use std::panic::catch_unwind;

fn guarded(req: &[u8]) -> String {
    catch_unwind(|| api::call(req))
        .unwrap_or_else(|_| r#"{"ok":false,"error":"panic","message":"核心库内部错误"}"#.to_string())
}

/// 调用核心库：req 为 UTF-8 JSON；结果写入 *out（UTF-8 JSON，用 hj_free 释放）。返回 0；参数为空指针时返回 1。
#[no_mangle]
pub unsafe extern "C" fn hj_call(req: *const u8, len: usize, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    if req.is_null() || out.is_null() || out_len.is_null() {
        return 1;
    }
    let res = guarded(std::slice::from_raw_parts(req, len)).into_bytes().into_boxed_slice();
    *out_len = res.len();
    *out = Box::into_raw(res) as *mut u8;
    0
}

/// 释放 hj_call 返回的缓冲区
#[no_mangle]
pub unsafe extern "C" fn hj_free(p: *mut u8, len: usize) {
    if !p.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, len)));
    }
}

/// 安卓：io.github.hongyile.huijian.Core.call(ByteArray): ByteArray（用字节数组，避开 JNI 字符串的 modified UTF-8）
#[cfg(feature = "android")]
#[no_mangle]
pub extern "system" fn Java_io_github_hongyile_huijian_Core_call<'l>(
    env: jni::JNIEnv<'l>,
    _class: jni::objects::JClass<'l>,
    req: jni::objects::JByteArray<'l>,
) -> jni::sys::jbyteArray {
    let input = env.convert_byte_array(&req).unwrap_or_default();
    let res = guarded(&input);
    match env.byte_array_from_slice(res.as_bytes()) {
        Ok(a) => a.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}
