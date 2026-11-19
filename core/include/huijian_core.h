// 回笺共用核心的 C 接口（Rust 实现，见 core/src/ffi.rs、core/src/api.rs）
#pragma once
#include <stddef.h>
#include <stdint.h>

// 传入 UTF-8 JSON 请求，*out 收到 UTF-8 JSON 结果（必须用 hj_free 释放）。返回 0；参数为空指针时返回 1。
int32_t hj_call(const uint8_t *req, size_t len, uint8_t **out, size_t *out_len);
void hj_free(uint8_t *p, size_t len);
