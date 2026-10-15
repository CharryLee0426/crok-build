package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.PlanEntry

/** The pinned plan bar: "Plan 3/7 · Write tests". */
data class PlanSummary(
    val done: Int,
    val total: Int,
    /** The item in progress, else the next pending one, else the last one. */
    val current: String?,
) {
    val finished: Boolean get() = total > 0 && done == total

    companion object {
        const val COMPLETED = "completed"
        const val IN_PROGRESS = "in_progress"
        const val PENDING = "pending"

        fun of(plan: List<PlanEntry>): PlanSummary? {
            if (plan.isEmpty()) return null
            val done = plan.count { it.status == COMPLETED }
            val current = plan.firstOrNull { it.status == IN_PROGRESS }
                ?: plan.firstOrNull { it.status != COMPLETED }
                ?: plan.last()
            return PlanSummary(done, plan.size, current.content.trim().lineSequence().firstOrNull()?.takeIf { it.isNotBlank() })
        }
    }
}
