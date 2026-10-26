package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.EffortChoice
import dev.chenli.crok.mobile.data.ModelChoice

/** One section of Choose a Model: a provider's models; [provider] null for ids without one (named after the computer). */
data class ModelSection(val provider: String?, val models: List<ModelChoice>)

/** What a new session will start with: picked on the new-session screen, sent with its first prompt. Null: Default. */
data class SetupChoice(val model: String? = null, val effort: String? = null)

/** A change on its way to the session's computer (`commands:setConfig` until `commands:get` says done or failed). */
data class SetupChange(val model: String? = null, val effort: String? = null) {
    val any: Boolean get() = model != null || effort != null
}

/**
 * One pill of the setup row. [label] null says "Default". [busy]: a change is on its way (a spinner in place of the
 * chevron). [enabled]: taps open the picker. [dimmed]: the computer offers no list (a tap says so).
 */
data class SetupPill(
    val label: String?,
    val busy: Boolean = false,
    val enabled: Boolean = true,
    val dimmed: Boolean = false,
)

/** The setup row above the composer's field: the model pill, and the thinking pill when the model has levels. */
data class SetupRow(val model: SetupPill, val thinking: SetupPill? = null)

/**
 * The model and thinking-level pickers (mobile/DESIGN.md "Model and thinking level"): what the session's computer offers
 * (`devices:models`), grouped by provider for Choose a Model, and the pills that show the current choice.
 */
object ModelSetup {
    /** A model id's provider: the id up to its first `/` (`openrouter/qwen/qwen3-coder` → `openrouter`); null without one. */
    fun provider(id: String): String? = id.indexOf('/').takeIf { it > 0 }?.let { id.substring(0, it) }

    /** Search: a case-insensitive substring of the name, the id or the description. */
    fun matches(model: ModelChoice, query: String): Boolean {
        val wanted = query.trim()
        if (wanted.isEmpty()) return true
        return model.name.contains(wanted, ignoreCase = true) ||
            model.id.contains(wanted, ignoreCase = true) ||
            model.description?.contains(wanted, ignoreCase = true) == true
    }

    /**
     * The sheet's sections: by provider, in the order the providers first appear; sections without a match left out. A
     * model listed twice shows once (its first place).
     */
    fun sections(models: List<ModelChoice>, query: String = ""): List<ModelSection> {
        val groups = LinkedHashMap<String?, MutableList<ModelChoice>>()
        val seen = HashSet<String>()
        for (model in models) {
            if (matches(model, query) && seen.add(model.id)) groups.getOrPut(provider(model.id)) { ArrayList() }.add(model)
        }
        return groups.map { (provider, list) -> ModelSection(provider, list) }
    }

    /** A thinking level of [model] by its option id. */
    fun effort(model: ModelChoice?, id: String?): EffortChoice? =
        if (id == null) null else model?.efforts?.firstOrNull { it.id == id }

    /**
     * The setup row for a session (or, with [newSession], the new-session screen), or null when it has none:
     * - hidden when the composer cannot send ([available] false: the computer is offline, or the session is gone) and
     *   while the session is [starting] (it already carries its choice);
     * - without a list ([models] null: an older crok there) the session's model, dimmed; nothing when there is no model
     *   name either — and nothing on the new-session screen;
     * - while the list is [loading] (none yet, nothing to fall back on) the session's model, not tappable yet;
     * - on the new-session screen "Default" until [picked]; the thinking pill only once a model with levels is picked;
     * - in a session the current model and level, or the ones [changing] to (busy) until the computer applied them.
     */
    fun row(
        newSession: Boolean,
        models: List<ModelChoice>?,
        model: String?,
        effort: String?,
        available: Boolean,
        starting: Boolean = false,
        loading: Boolean = false,
        picked: SetupChoice = SetupChoice(),
        changing: SetupChange = SetupChange(),
    ): SetupRow? {
        if (!available) return null
        if (newSession) {
            if (models == null) return null
            val chosen = picked.model?.let { id -> models.firstOrNull { it.id == id } }
            val thinking = chosen?.takeIf { it.efforts.isNotEmpty() }?.let { SetupPill(effort(it, picked.effort)?.label) }
            return SetupRow(SetupPill(chosen?.label), thinking)
        }
        if (starting) return null
        if (models == null) {
            val name = model?.takeIf { it.isNotBlank() } ?: return null
            return SetupRow(SetupPill(name, enabled = !loading, dimmed = !loading))
        }
        val current = ModelChoice.find(models, model)
        val target = changing.model?.let { id -> models.firstOrNull { it.id == id } } ?: current
        val modelLabel = when {
            changing.model != null -> target?.label ?: changing.model
            current != null -> current.label
            else -> model?.takeIf { it.isNotBlank() }
        }
        val modelPill = SetupPill(modelLabel, busy = changing.model != null, enabled = !changing.any)
        val thinking = target?.takeIf { it.efforts.isNotEmpty() }?.let { shown ->
            val level = effort(shown, changing.effort) ?: ComposerCommands.currentEffort(shown, effort)
            SetupPill(level?.label, busy = changing.effort != null, enabled = !changing.any)
        }
        return SetupRow(modelPill, thinking)
    }
}
