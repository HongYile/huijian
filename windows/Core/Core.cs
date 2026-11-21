using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;

namespace Huijian;

/// 回笺共用核心（Rust，见 core/src/api.rs）：端到端加密、Markdown 解析、密码强度检查。
/// 只有一个入口 hj_call：JSON 进、JSON 出（和 Mac / iPhone 的 Core.swift、安卓的 Core.kt 一致）。
public static partial class Core
{
    public sealed class Failure(string code, string message) : Exception(message)
    {
        /// bad_request / format / wrong_key / io / weak_params / panic
        public string Code { get; } = code;
    }

    [LibraryImport("huijian_core")]
    private static unsafe partial int hj_call(byte* req, nuint len, out byte* res, out nuint resLen);

    [LibraryImport("huijian_core")]
    private static unsafe partial void hj_free(byte* p, nuint len);

    /// 调用核心库；失败抛 Failure
    public static unsafe JsonObject Call(string op, JsonObject? args = null)
    {
        var req = args?.DeepClone().AsObject() ?? new JsonObject();
        req["op"] = op;
        var data = Encoding.UTF8.GetBytes(req.ToJsonString());
        byte* res;
        nuint n;
        int rc;
        fixed (byte* p = data) rc = hj_call(p, (nuint)data.Length, out res, out n);
        if (rc != 0 || res == null) throw new Failure("panic", "核心库调用失败");
        string text;
        try { text = Encoding.UTF8.GetString(res, checked((int)n)); }
        finally { hj_free(res, n); }
        var obj = JsonNode.Parse(text) as JsonObject ?? throw new Failure("format", "核心库返回了无法识别的结果");
        if (obj["ok"]?.GetValue<bool>() == true) return obj;
        throw new Failure(obj["error"]?.GetValue<string>() ?? "unknown", obj["message"]?.GetValue<string>() ?? "核心库返回了无法识别的结果");
    }

    public static string Version() => Call("version")["version"]!.GetValue<string>();
}
