# Keep this file targeted. R8/AGP release optimization remains enabled.

# UniFFI's stable Kotlin backend uses JNA on Android.
-dontwarn java.awt.**
-keep class com.sun.jna.** { *; }
-keep class * extends com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }
