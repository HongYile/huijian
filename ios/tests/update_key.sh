# 测试用的更新签名密钥（不是发布密钥）：selftest.sh / sim_shots.sh 在构建 App 之前 source，
# 构建时把它的公钥当作 App 内置的更新公钥（UPDATE_PUBKEY），再用私钥在测试 hub 上发布一个假的新版本，
# App 内「下载并用 GBox 安装」就能完整走一遍下载 → sha256 → 签名校验。
# 导出：TEST_UPDATE_KEY（私钥文件）TEST_UPDATE_PUB（公钥）
(cd ../server && GOTOOLCHAIN=local go build -o bin/huijian .) || { echo "❌ 服务端编译失败"; exit 1; }
TEST_UPDATE_KEY=/tmp/huijian-ios-test-update.key
rm -f "$TEST_UPDATE_KEY"
TEST_UPDATE_PUB=$(../server/bin/huijian release-key "$TEST_UPDATE_KEY") || { echo "❌ 生成测试密钥失败"; exit 1; }
[ -n "$TEST_UPDATE_PUB" ] || { echo "❌ 测试公钥为空"; exit 1; }
