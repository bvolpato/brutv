# These names form the encrypted profile file's versioned JSON schema.
-keep class com.bvolpato.brutv.data.SourceConfig { *; }
-keep class com.bvolpato.brutv.data.SourceType { *; }
-keep class com.bvolpato.brutv.data.SavedState { *; }
-keep class com.bvolpato.brutv.data.LibraryState { *; }

# Debug, release, and future builds must share the versioned TV pairing schema.
-keep class com.bvolpato.brutv.signin.PairingEnvelope { *; }
-keep class com.bvolpato.brutv.signin.PairingPayload { *; }
