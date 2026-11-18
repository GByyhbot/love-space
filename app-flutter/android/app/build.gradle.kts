import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 2.4.3 提交二：正式签名接法（第 3 项）─────────────────────────────
// 硬性兼容口径：只有 apk-release.yml 注入钥匙（环境变量 LOVE_KEY_PROPERTIES
// 指向 key.properties，四项齐全）才启用正式签名；本机开发 / flutter test /
// flutter-ci（analyze+test+debug APK）等无该环境时自动退回 debug 签名，
// 任何既有本地/CI 流程不得被本项改坏。key.properties 与 keystore 文件都
// 只落 CI 的 $RUNNER_TEMP（仓库外临时目录），禁止进工作区与 artifact。
// 写法刻意保守（无 apply/takeIf 链）：kts 编译环境差异下最不易碎。
val keystoreProps = Properties()
val keystorePropsFile: File? = System.getenv("LOVE_KEY_PROPERTIES")?.let {
    val f = File(it)
    if (f.isFile) f else null
}
if (keystorePropsFile != null) {
    keystorePropsFile.inputStream().use { keystoreProps.load(it) }
}
val ksStoreFile = keystoreProps.getProperty("storeFile")
val ksStorePass = keystoreProps.getProperty("storePassword")
val ksKeyAlias = keystoreProps.getProperty("keyAlias")
val ksKeyPass = keystoreProps.getProperty("keyPassword")
val hasReleaseSigning = (keystorePropsFile != null &&
    ksStoreFile != null && ksStorePass != null &&
    ksKeyAlias != null && ksKeyPass != null)

android {
    namespace = "cn.iepose.lovespace.love_space"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // 2.4.5 乙组：flutter_local_notifications 23 的 AAR 元数据要求
    // compileSdk >= 37（checkReleaseAarMetadata 硬校验）；flutter 工具链默认
    // 36（AGP 9.1.0 对 37 仅「recommended max」警告，不阻塞）。compileSdk
    // 只影响编译期可见 API，targetSdk/minSdk 不动（运行时行为与装机面不变）。
    compileSdk = 37

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // 2.4.5 乙组：flutter_local_notifications 23 明文要求启用 core library
        // desugaring（checkReleaseAarMetadata 硬校验，run 44330022473 根因）
        coreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cn.iepose.lovespace.love_space"
        // You can update the following values to match your application.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(ksStoreFile!!)
                storePassword = ksStorePass
                keyAlias = ksKeyAlias
                keyPassword = ksKeyPass
            }
        }
    }

    buildTypes {
        release {
            // 正式签名只在 CI 注入钥匙时启用；否则回退 debug 签名
            // （保持 flutter run --release 等本地流程原样可用）。
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// 2.4.5 乙组：core library desugaring 依赖（随 coreLibraryDesugaringEnabled；
// 2.1.4 需 AGP 8.4+，本工程 AGP 9.1.0 满足）
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
