# flutter_local_notifications 用 Gson 把"排期中的通知"持久化到 SharedPreferences。
#
# R8 默认会把泛型签名和模型类的字段剥掉，反序列化时抛
#   java.lang.RuntimeException: Missing type parameter
# 表现极其隐蔽：闹钟**排上了**（dumpsys alarm 看得到），到点**什么都不发生**，
# 通知栏永远空着，只有 logcat 里一行 RuntimeException。
#
# 这个坑在 6.1.0 的番茄钟上真踩过：debug 正常、release 到点不响。
-keepattributes Signature
-keepattributes *Annotation*

-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keepclassmembers class com.dexterous.flutterlocalnotifications.** { *; }

# Gson 反射读字段，同样不能被裁
-keep class com.google.gson.** { *; }
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
