# Preserve generic type signatures for Gson deserialization in minified builds.
-keepattributes Signature

# These names form the encrypted profile file's and local preferences file's JSON schema.
-keep class com.bvolpato.brutv.data.SourceConfig { *; }
-keep class com.bvolpato.brutv.data.SourceType { *; }
-keep class com.bvolpato.brutv.data.SavedState { *; }
-keep class com.bvolpato.brutv.data.LibraryState { *; }
-keep class com.bvolpato.brutv.data.PreferencesState { *; }

# Debug, release, and future builds must share the versioned TV pairing schema.
-keep class com.bvolpato.brutv.signin.PairingEnvelope { *; }
-keep class com.bvolpato.brutv.signin.PairingPayload { *; }
