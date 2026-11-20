//! 回笺共用核心：端到端加密 + Markdown 解析 + 密码强度检查。格式规格见 docs/e2ee.md、docs/api.md。
//! 各端只通过 `hj_call`（JSON 进、JSON 出，见 api.rs）使用；不碰网络，文件只在解密附件时读写调用方给的路径。

pub mod agent;
pub mod api;
pub mod crypto;
pub mod ffi;
pub mod md;
pub mod password;
