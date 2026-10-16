package dev.chenli.crok.mobile.logic

import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.Locale

/** The session list's trailing time, Telegram style: a time today, a weekday this week, a date before that. */
sealed interface ListTime {
    data class Today(val time: LocalTime) : ListTime
    data class ThisWeek(val date: LocalDate) : ListTime
    data class ThisYear(val date: LocalDate) : ListTime
    data class Older(val date: LocalDate) : ListTime
}

/** "last seen …" and similar: how long ago, in the coarsest unit that reads naturally. */
sealed interface Ago {
    data object JustNow : Ago
    data class Minutes(val count: Int) : Ago
    data class Hours(val count: Int) : Ago
    data class Yesterday(val time: LocalTime) : Ago
    data class Days(val count: Int) : Ago
    data class OnDate(val date: LocalDate) : Ago
}

/** A day header in the transcript. */
sealed interface DayLabel {
    data object Today : DayLabel
    data object Yesterday : DayLabel
    data class ThisYear(val date: LocalDate) : DayLabel
    data class Older(val date: LocalDate) : DayLabel
}

object RelativeTime {
    fun listTime(atMillis: Long, nowMillis: Long, zone: ZoneId): ListTime {
        val at = Instant.ofEpochMilli(atMillis).atZone(zone)
        val today = Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate()
        val day = at.toLocalDate()
        val daysAgo = ChronoUnit.DAYS.between(day, today)
        return when {
            daysAgo <= 0 -> ListTime.Today(at.toLocalTime())
            daysAgo < 7 -> ListTime.ThisWeek(day)
            day.year == today.year -> ListTime.ThisYear(day)
            else -> ListTime.Older(day)
        }
    }

    fun ago(atMillis: Long, nowMillis: Long, zone: ZoneId): Ago {
        val elapsed = (nowMillis - atMillis).coerceAtLeast(0)
        val minutes = (elapsed / 60_000).toInt()
        val at = Instant.ofEpochMilli(atMillis).atZone(zone)
        val today = Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate()
        val daysAgo = ChronoUnit.DAYS.between(at.toLocalDate(), today)
        return when {
            minutes < 1 -> Ago.JustNow
            minutes < 60 -> Ago.Minutes(minutes)
            daysAgo <= 0L -> Ago.Hours(minutes / 60)
            daysAgo == 1L -> Ago.Yesterday(at.toLocalTime())
            daysAgo < 7 -> Ago.Days(daysAgo.toInt())
            else -> Ago.OnDate(at.toLocalDate())
        }
    }

    fun dayLabel(day: LocalDate, nowMillis: Long, zone: ZoneId): DayLabel {
        val today = Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate()
        return when {
            day == today -> DayLabel.Today
            day == today.minusDays(1) -> DayLabel.Yesterday
            day.year == today.year -> DayLabel.ThisYear(day)
            else -> DayLabel.Older(day)
        }
    }

    /** "9:41" for a countdown (expires in …). */
    fun countdown(remainingMillis: Long): String {
        val seconds = (remainingMillis.coerceAtLeast(0) + 999) / 1000
        return String.format(Locale.ROOT, "%d:%02d", seconds / 60, seconds % 60)
    }
}
