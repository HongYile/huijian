import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// 版本号来自 android/VERSION；构建号默认取 git 提交数（与 Mac 端一致），可用 -PbuildNumber=N 覆盖
val appVersion = rootProject.file("VERSION").readText().trim()
val buildNumber = (findProperty("buildNumber") as String?)?.toInt()
    ?: runCatching {
        ProcessBuilder("git", "rev-list", "--count", "HEAD").directory(rootDir).start()
            .inputStream.bufferedReader().readText().trim().toInt()
    }.getOrDefault(1)
// 登录页预填的服务器地址：-PdefaultServer=https://push.example.com（公开构建留空）
val defaultServer = (findProperty("defaultServer") as String?) ?: ""
// 正式版签名：android/signing.local.properties（已被 git 忽略）里写 signing=<签名配置文件路径>，
// 签名配置文件含 storeFile / storePassword / keyAlias / keyPassword。没有时 release 构建不签名。
val signingProps = rootProject.file("signing.local.properties").takeIf { it.exists() }?.let { f ->
    val local = Properties().apply { f.inputStream().use { load(it) } }
    local.getProperty("signing")?.let { path -> Properties().apply { file(path).inputStream().use { load(it) } } }
}

android {
    namespace = "io.github.hongyile.huijian"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.github.hongyile.huijian"
        minSdk = 26
        targetSdk = 36
        versionCode = buildNumber
        versionName = appVersion
        buildConfigField("String", "DEFAULT_SERVER", "\"$defaultServer\"")
        ndk { abiFilters += "arm64-v8a" } // 共用核心只编译 arm64（真机和 Apple 芯片 Mac 上的模拟器都是）
    }

    signingConfigs {
        if (signingProps != null) create("release") {
            storeFile = file(signingProps.getProperty("storeFile"))
            storePassword = signingProps.getProperty("storePassword")
            keyAlias = signingProps.getProperty("keyAlias")
            keyPassword = signingProps.getProperty("keyPassword")
        }
    }
    buildTypes {
        release {
            if (signingProps != null) signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}

kotlin { compilerOptions { jvmTarget.set(JvmTarget.JVM_17) } }

// 共用核心（Rust：端到端加密、Markdown 解析）→ src/main/jniLibs/arm64-v8a/libhuijian_core.so。需要 Rust 和 NDK，见 core/build.sh
val buildCore by tasks.registering(Exec::class) {
    val core = rootProject.file("../core")
    workingDir = core
    commandLine("./build.sh", "android")
    inputs.dir(core.resolve("src"))
    inputs.file(core.resolve("Cargo.toml"))
    outputs.file(file("src/main/jniLibs/arm64-v8a/libhuijian_core.so"))
}
tasks.named("preBuild") { dependsOn(buildCore) }

// 可选的本机端到端测试（E2EHostTest）：HUIJIAN_CORE_HOST_LIB 指向本机编译的核心库目录（libhuijian_core.dylib，带 JNI 导出），
// 单元测试就能加载真实的共用核心；没设置时 E2EHostTest 自动跳过。用法见 E2EHostTest 的注释
tasks.withType<Test>().configureEach {
    System.getenv("HUIJIAN_CORE_HOST_LIB")?.let { systemProperty("java.library.path", it) }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.11.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")      // 单元测试跑在 JVM 上，android.jar 里的 org.json 只是空壳
}
