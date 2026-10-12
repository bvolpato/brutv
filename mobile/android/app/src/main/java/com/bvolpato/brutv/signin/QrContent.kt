package com.bvolpato.brutv.signin

import com.bvolpato.brutv.data.LoginLinks
import java.util.concurrent.atomic.AtomicBoolean

internal fun supportedQrContent(raw: String): String? = runCatching {
    raw.trim().takeIf { text ->
        text.length in 1..8192 && (LoginLinks.parse(text) != null || Pairing.parseInvite(text) != null)
    }
}.getOrNull()

internal fun claimSupportedQr(raw: String, delivered: AtomicBoolean): String? {
    val supported = supportedQrContent(raw) ?: return null
    return supported.takeIf { delivered.compareAndSet(false, true) }
}
