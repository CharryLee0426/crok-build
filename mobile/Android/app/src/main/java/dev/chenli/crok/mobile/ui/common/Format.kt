package dev.chenli.crok.mobile.ui.common

import android.content.Context
import android.icu.text.CompactDecimalFormat
import android.icu.text.SimpleDateFormat
import android.text.format.DateFormat
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.logic.Ago
import dev.chenli.crok.mobile.logic.DayLabel
import dev.chenli.crok.mobile.logic.ListTime
import java.text.NumberFormat
import java.time.LocalDate
import java.time.ZoneId
import java.util.Currency
import java.util.Date
import java.util.Locale

/** Locale-aware formatting for times, dates, token counts and costs. */
class Formatter(private val context: Context, val locale: Locale, val zone: ZoneId = ZoneId.systemDefault()) {
    /** ICU's formatter: best patterns use ICU letters (`ccc` for a stand-alone weekday) that java.text rejects. */
    private fun pattern(skeleton: String) = SimpleDateFormat(DateFormat.getBestDateTimePattern(locale, skeleton), locale)

    private fun millis(date: LocalDate) = date.atStartOfDay(zone).toInstant().toEpochMilli()

    fun time(atMillis: Long): String = DateFormat.getTimeFormat(context).format(Date(atMillis))

    fun listTime(value: ListTime): String = when (value) {
        is ListTime.Today -> DateFormat.getTimeFormat(context).format(
            Date(value.time.atDate(LocalDate.now(zone)).atZone(zone).toInstant().toEpochMilli()),
        )
        is ListTime.ThisWeek -> pattern("EEE").format(Date(millis(value.date)))
        is ListTime.ThisYear -> pattern("MMMd").format(Date(millis(value.date)))
        is ListTime.Older -> pattern("yMd").format(Date(millis(value.date)))
    }

    fun dayLabel(value: DayLabel): String = when (value) {
        DayLabel.Today -> context.getString(R.string.day_today)
        DayLabel.Yesterday -> context.getString(R.string.day_yesterday)
        is DayLabel.ThisYear -> pattern("EEEEMMMMd").format(Date(millis(value.date)))
        is DayLabel.Older -> pattern("yMMMMd").format(Date(millis(value.date)))
    }

    fun ago(value: Ago): String {
        val res = context.resources
        return when (value) {
            Ago.JustNow -> res.getString(R.string.ago_just_now)
            is Ago.Minutes -> res.getQuantityString(R.plurals.ago_minutes, value.count, value.count)
            is Ago.Hours -> res.getQuantityString(R.plurals.ago_hours, value.count, value.count)
            is Ago.Yesterday -> res.getString(
                R.string.ago_yesterday,
                DateFormat.getTimeFormat(context).format(Date(value.time.atDate(LocalDate.now(zone)).atZone(zone).toInstant().toEpochMilli())),
            )
            is Ago.Days -> res.getQuantityString(R.plurals.ago_days, value.count, value.count)
            is Ago.OnDate -> res.getString(R.string.ago_on_date, pattern("yMMMd").format(Date(millis(value.date))))
        }
    }

    fun dateTime(atMillis: Long): String = pattern("yMMMdjmm").format(Date(atMillis))

    /** 182400 → "182K" (localized, e.g. "18万"). */
    fun compact(value: Long): String {
        if (value < 10_000) return NumberFormat.getIntegerInstance(locale).format(value)
        val format = CompactDecimalFormat.getInstance(locale, CompactDecimalFormat.CompactStyle.SHORT)
        format.maximumFractionDigits = 1
        return format.format(value)
    }

    fun cost(usd: Double): String {
        val format = NumberFormat.getCurrencyInstance(locale)
        format.currency = Currency.getInstance("USD")
        format.maximumFractionDigits = if (usd > 0 && usd < 0.01) 4 else 2
        format.minimumFractionDigits = 2
        return format.format(usd)
    }
}

@Composable
@ReadOnlyComposable
fun rememberFormatter(): Formatter {
    val locale = LocalConfiguration.current.locales[0] ?: Locale.ROOT
    return Formatter(LocalContext.current, locale)
}
