# AMap 3D Map SDK v9.8.3: prevent R8 from stripping or renaming JNI_OnLoad targets
-keep class com.amap.api.** { *; }
-keep interface com.amap.api.** { *; }
-keep class com.autonavi.** { *; }
-keep interface com.autonavi.** { *; }
-keep class com.loc.** { *; }
-dontwarn com.amap.api.**
-dontwarn com.autonavi.**
-dontwarn com.loc.**
