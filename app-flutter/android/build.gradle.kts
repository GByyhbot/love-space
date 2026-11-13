allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// file_picker 插件自钉 compileSdk 34，而其传递依赖 flutter_plugin_android_lifecycle
// 的 AAR 元数据要求消费方 compileSdk ≥36（2026-11-14 引入 file_picker 供歌单
// 本地音频上传时发现）——反射把该子项目抬到 36（与应用一致，不影响其它插件）。
// 🔴 只对 file_picker 调 afterEvaluate：:app 已被 evaluationDependsOn 提前评估，
// 无过滤会对它抛 "already evaluated"。
subprojects {
    if (project.name == "file_picker") {
        afterEvaluate {
            project.extensions.findByName("android")?.let { ext ->
                ext.javaClass.methods
                    .firstOrNull { it.name == "setCompileSdk" }
                    ?.invoke(ext, 36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
