# okhttp 自带 consumer 规则；本项目不用反射序列化
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# 共用核心的 JNI 入口（Core.call）：名字必须保持不变
-keep class io.github.hongyile.huijian.Core { native <methods>; }
