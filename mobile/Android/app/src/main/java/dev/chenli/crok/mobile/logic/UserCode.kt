package dev.chenli.crok.mobile.logic

import java.net.URLDecoder

/**
 * Device sign-in user codes (`BCDF-GHJK`). The relay accepts any case and spacing; the phone normalizes what is typed
 * or scanned so the confirmation screen always shows the canonical form.
 */
object UserCode {
    const val LENGTH = 8

    /** `bcdf ghjk`, `BCDFGHJK`, `bcdf-ghjk` → `BCDF-GHJK`; null unless exactly eight letters remain. */
    fun normalize(input: String): String? {
        val letters = input.uppercase().filter { it in 'A'..'Z' }
        if (letters.length != LENGTH) return null
        return "${letters.substring(0, 4)}-${letters.substring(4)}"
    }

    /** Formats partial input while typing: uppercase letters only, a dash after the fourth. */
    fun formatTyping(input: String): String {
        val letters = input.uppercase().filter { it in 'A'..'Z' }.take(LENGTH)
        return if (letters.length > 4) "${letters.substring(0, 4)}-${letters.substring(4)}" else letters
    }

    /**
     * Reads a scanned QR: the link `crok remote login` prints (`https://…/link?code=BCDF-GHJK`, any scheme), or a bare
     * code. Null when it is not a crok sign-in code.
     */
    fun fromScan(raw: String): String? {
        val text = raw.trim()
        val query = text.substringAfter('?', missingDelimiterValue = "")
        if (query.isNotEmpty()) {
            for (part in query.split('&')) {
                val name = part.substringBefore('=')
                if (name == "code") {
                    val value = runCatching { URLDecoder.decode(part.substringAfter('=', ""), "UTF-8") }.getOrNull()
                    return value?.let(::normalize)
                }
            }
            return null
        }
        if (text.contains("://")) return null
        return normalize(text)
    }
}
