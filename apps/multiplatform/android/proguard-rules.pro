# ChatFort R8 rules.
#
# R8 shrinks and obfuscates the third-party libraries (Compose, AndroidX, Kotlin, coroutines, QR
# scanner, ...), which ship their own consumer rules. All of ChatFort's own code is kept exactly as
# it is: it is reached by name from the Haskell core over JNI, from the call WebView's JavaScript
# bridge, by kotlinx.serialization (chat core JSON) and by moko resources (MR).

-keep class chat.simplex.** { *; }
-keep interface chat.simplex.** { *; }
-keep enum chat.simplex.** { *; }

# JNI: native methods and the classes in their signatures
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# WebView JavaScript bridge
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# kotlinx.serialization: annotations, generics and companion serializers
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod, Exceptions
-keepclassmembers class * {
    @kotlinx.serialization.Serializable *;
}

# Readable crash stack traces (upload the mapping file to Play Console)
-keepattributes SourceFile, LineNumberTable
-renamesourcefileattribute SourceFile
