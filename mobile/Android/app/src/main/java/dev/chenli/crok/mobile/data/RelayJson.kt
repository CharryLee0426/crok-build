package dev.chenli.crok.mobile.data

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive

/**
 * The one JSON configuration for everything that crosses the relay: lenient about missing and unknown fields, because
 * the relay may add fields and a subscription that fails to decode would go silent.
 */
val RelayJson: Json = Json {
    ignoreUnknownKeys = true
    coerceInputValues = true
    explicitNulls = false
    isLenient = true
    encodeDefaults = true
}

/**
 * Convex numbers are float64 (`v.number()`): timestamps and counts arrive as `1760500000000` or `3.0`, and the API wants
 * them back as floats, never as int64. These serializers read either form into a Kotlin [Long] / [Int] and write a
 * double.
 */
object WireLongSerializer : KSerializer<Long> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("crok.WireLong", PrimitiveKind.DOUBLE)

    override fun deserialize(decoder: Decoder): Long {
        if (decoder is JsonDecoder) {
            val element = decoder.decodeJsonElement()
            val primitive = when (element) {
                is JsonPrimitive -> element
                // Convex's tagged int64 (`{"$integer": base64}`) never appears in this API; read it as 0 rather than fail.
                is JsonObject -> return 0
                else -> return 0
            }
            return primitive.doubleOrNull?.toLong() ?: primitive.content.toLongOrNull() ?: 0
        }
        return decoder.decodeDouble().toLong()
    }

    override fun serialize(encoder: Encoder, value: Long) = encoder.encodeDouble(value.toDouble())
}

object WireIntSerializer : KSerializer<Int> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("crok.WireInt", PrimitiveKind.DOUBLE)

    override fun deserialize(decoder: Decoder): Int = WireLongSerializer.deserialize(decoder).toInt()

    override fun serialize(encoder: Encoder, value: Int) = encoder.encodeDouble(value.toDouble())
}

/** A float64 on the wire that a Kotlin field keeps as a [Long] (timestamps, sequence numbers, token counts). */
typealias WireLong = @Serializable(WireLongSerializer::class) Long

/** A float64 on the wire that a Kotlin field keeps as an [Int] (small counts). */
typealias WireInt = @Serializable(WireIntSerializer::class) Int

/** Reads a float64 field from a loose JSON object (info results), or null. */
internal fun JsonObject.number(key: String): Double? = (this[key] as? JsonPrimitive)?.let {
    if (it.isString) it.content.toDoubleOrNull() else it.jsonPrimitive.doubleOrNull
}

internal fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

internal fun JsonObject.boolean(key: String): Boolean? =
    (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
