package dev.chenli.crok.mobile.demo

import android.content.Context
import dev.chenli.crok.mobile.data.O11yPageState
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.data.RelayJson
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

/**
 * The o11y tab in demo mode (mobile/DESIGN.md "o11y", Demo mode; DemoO11y.swift on iOS): pages from the bundled
 * `o11y-demo.json`, which `relay/scripts/o11y-demo.mjs` makes from real pages with the owner's data swapped out. Text
 * goes through the relay's own translations, times move to now, and a refresh only moves `builtAt`. [forced] shows
 * the forbidden or unconfigured state instead (tests).
 */
class DemoO11y(
    fixture: String,
    private val clock: () -> Long = System::currentTimeMillis,
    private val forced: O11yPageState.State? = null,
    private val refreshDelayMs: Long = 400,
) {
    private val root: JsonObject = RelayJson.parseToJsonElement(fixture).jsonObject
    private val fixtureBuiltAt: Double = (root["builtAt"] as? JsonPrimitive)?.doubleOrNull ?: 0.0
    private val pages: JsonObject = root["pages"] as? JsonObject ?: JsonObject(emptyMap())
    private val strings: Map<String, Map<String, String>> = (root["strings"] as? JsonObject).orEmpty().mapValues { (_, value) ->
        (value as? JsonObject).orEmpty().mapValues { (_, text) -> (text as? JsonPrimitive)?.content.orEmpty() }
    }

    /** When each `page|lang` was last "built" (refreshed). */
    private val built = MutableStateFlow<Map<String, Long>>(emptyMap())

    /** The fixture's text in [lang]: a known string, else each " · " part that is known. */
    fun translate(text: String, lang: String): String {
        if (lang == "en") return text
        strings[text]?.get(lang)?.let { return it }
        if (!text.contains(" · ")) return text
        return text.split(" · ").joinToString(" · ") { strings[it]?.get(lang) ?: it }
    }

    /** What `o11y:page` answers for these arguments. */
    fun answer(args: Map<String, Any?>): JsonElement {
        forced?.takeIf { it != O11yPageState.State.OK }?.let { state ->
            return buildJsonObject { put("state", if (state == O11yPageState.State.FORBIDDEN) "forbidden" else "unconfigured") }
        }
        val id = args["page"] as? String ?: ""
        val lang = args["lang"] as? String ?: "en"
        val base = pages[id] as? JsonObject ?: return buildJsonObject {
            put("state", "ok")
            put("page", JsonNull)
            put("refreshing", false)
        }
        val at = built.value["$id|$lang"] ?: (clock() - 30_000)
        val shift = at - fixtureBuiltAt
        var page = localize(base, lang, shift) as JsonObject
        val ranges = (page["ranges"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty()
        val range = args["range"] as? String
        page = JsonObject(
            page + mapOf(
                "builtAt" to JsonPrimitive(at.toDouble()),
                "range" to (if (range != null && range in ranges) JsonPrimitive(range) else page["range"] ?: JsonPrimitive("")),
            ),
        )
        return buildJsonObject {
            put("state", "ok")
            put("page", page)
            put("builtAt", at.toDouble())
            put("refreshing", false)
            put("error", JsonNull)
        }
    }

    fun page(args: Map<String, Any?>): Flow<Result<JsonElement>> =
        built.map { runCatching { answer(args) } }.distinctUntilChanged()

    /** `o11y:refresh`: the page is "built" anew after a moment. */
    suspend fun refresh(args: Map<String, Any?>): JsonElement {
        forced?.takeIf { it != O11yPageState.State.OK }?.let { state ->
            throw RelayException(
                if (state == O11yPageState.State.FORBIDDEN) RelayErrorCode.FORBIDDEN else RelayErrorCode.NOT_CONFIGURED,
                "",
            )
        }
        delay(refreshDelayMs)
        val key = "${args["page"]}|${args["lang"] ?: "en"}"
        val at = clock()
        built.update { it + (key to at) }
        return buildJsonObject {
            put("status", "built")
            put("builtAt", at.toDouble())
            put("error", JsonNull)
        }
    }

    /** The words the iOS demo translates (titles, labels, names, chips, notes, empty texts) and every time moved. */
    private fun localize(element: JsonElement, lang: String, shift: Double, key: String? = null): JsonElement = when (element) {
        is JsonObject -> JsonObject(
            element.mapValues { (k, v) ->
                when {
                    k == "time" && v is JsonPrimitive && v.doubleOrNull != null -> JsonPrimitive(v.doubleOrNull!! + shift)
                    k == "points" && v is JsonArray -> JsonArray(
                        v.map { point ->
                            val pair = point as? JsonArray
                            val time = (pair?.getOrNull(0) as? JsonPrimitive)?.doubleOrNull
                            if (pair == null || time == null) point else JsonArray(listOf(JsonPrimitive(time + shift)) + pair.drop(1))
                        },
                    )
                    else -> localize(v, lang, shift, k)
                }
            },
        )
        is JsonArray -> JsonArray(element.map { localize(it, lang, shift, key) })
        is JsonPrimitive -> if (element.isString && key in TEXT_KEYS) JsonPrimitive(translate(element.content, lang)) else element
    }

    companion object {
        private val TEXT_KEYS = setOf("title", "subtitle", "footer", "label", "name", "t", "empty", "text")

        fun fromAssets(context: Context, clock: () -> Long = System::currentTimeMillis): DemoO11y? = runCatching {
            DemoO11y(context.assets.open("o11y-demo.json").bufferedReader().use { it.readText() }, clock)
        }.getOrNull()
    }
}
