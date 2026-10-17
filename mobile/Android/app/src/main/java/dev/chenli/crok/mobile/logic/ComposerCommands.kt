package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.EffortChoice
import dev.chenli.crok.mobile.data.ModelChoice
import dev.chenli.crok.mobile.data.SlashCommand

/** The phone's own commands, handled on the phone (relay/DESIGN.md §5, "Commands in the composer"). */
enum class LocalCommand(val command: String, val takesArguments: Boolean) {
    /** `/new [prompt]`: a new session in this project. */
    New("new", true),

    /** `/model [name]`: the model, on the session's computer. */
    Model("model", true),

    /** `/think [level]`: the thinking level (only when the current model has levels). */
    Think("think", true),

    /** `/stop`: stop the running turn (only while it runs). */
    Stop("stop", false),

    /** `/info`: the session's info. */
    Info("info", false),
}

/** One row of the command list: the phone's own command, or one of the session's (sent as a prompt). */
data class CommandEntry(
    val name: String,
    val local: LocalCommand? = null,
    val description: String = "",
    val hint: String? = null,
) {
    /** Tapping it fills the field with `/name ` for the rest instead of sending it at once. */
    val takesArguments: Boolean get() = local?.takesArguments ?: (hint != null)
}

/** What the composer's text asks for. */
data class ParsedCommand(val name: String, val argument: String?, val local: LocalCommand?)

/** How an argument matched the choices of `/model` or `/think`. */
sealed interface ChoiceMatch<out T> {
    data class One<T>(val choice: T) : ChoiceMatch<T>
    data object Ambiguous : ChoiceMatch<Nothing>
    data object None : ChoiceMatch<Nothing>
}

object ComposerCommands {
    /** The phone's commands that apply to a session now. */
    fun local(running: Boolean, hasThinking: Boolean): List<LocalCommand> = LocalCommand.entries.filter {
        when (it) {
            LocalCommand.Think -> hasThinking
            LocalCommand.Stop -> running
            else -> true
        }
    }

    /**
     * The command list for [draft]: shown when the Menu button opened it on an empty field ([menuOpen]) or while the
     * field holds `/` and the start of a name (`/mo` → `/model`); the phone's commands first, then the session's, a
     * session command that shares a name with one of the phone's left out. Null: no list.
     */
    fun suggestions(draft: String, menuOpen: Boolean, local: List<CommandEntry>, session: List<SlashCommand>): List<CommandEntry>? {
        val typed = when {
            draft.startsWith("/") && draft.none { it.isWhitespace() } -> draft.drop(1)
            menuOpen && draft.isBlank() -> ""
            else -> return null
        }
        val localNames = local.mapTo(HashSet()) { it.name }
        val all = local + session.filter { it.name.isNotBlank() && it.name !in localNames }
            .map { CommandEntry(it.name, null, it.description, it.hint?.takeIf { hint -> hint.isNotBlank() }) }
        return all.filter { it.name.startsWith(typed, ignoreCase = true) }
    }

    /** `/name rest` → the name and the rest; null when [text] is not a command. */
    fun parse(text: String): ParsedCommand? {
        val trimmed = text.trim()
        if (!trimmed.startsWith("/") || trimmed.length < 2) return null
        val body = trimmed.drop(1)
        val name = body.takeWhile { !it.isWhitespace() }
        if (name.isEmpty()) return null
        val argument = body.drop(name.length).trim().ifEmpty { null }
        val local = LocalCommand.entries.firstOrNull { it.command.equals(name, ignoreCase = true) }
        return ParsedCommand(name, argument, local)
    }

    /** `/model <name>`: by id or name, ignoring case, exact first, else a unique prefix. */
    fun matchModel(argument: String, models: List<ModelChoice>): ChoiceMatch<ModelChoice> =
        match(argument, models) { listOf(it.id, it.name) }

    /** `/think <level>`: by id, canonical level or name, ignoring case, exact first, else a unique prefix. */
    fun matchEffort(argument: String, efforts: List<EffortChoice>): ChoiceMatch<EffortChoice> =
        match(argument, efforts) { listOfNotNull(it.id, it.value, it.name) }

    private fun <T> match(argument: String, choices: List<T>, keys: (T) -> List<String>): ChoiceMatch<T> {
        val wanted = argument.trim().lowercase()
        if (wanted.isEmpty()) return ChoiceMatch.None
        val exact = choices.filter { choice -> keys(choice).any { it.lowercase() == wanted } }
        if (exact.size == 1) return ChoiceMatch.One(exact.single())
        if (exact.size > 1) return ChoiceMatch.Ambiguous
        val prefixed = choices.filter { choice -> keys(choice).any { it.lowercase().startsWith(wanted) } }
        return when (prefixed.size) {
            0 -> ChoiceMatch.None
            1 -> ChoiceMatch.One(prefixed.single())
            else -> ChoiceMatch.Ambiguous
        }
    }

    /** The session's thinking level among [model]'s: the effort whose canonical level is the session's `effort`. */
    fun currentEffort(model: ModelChoice?, effort: String?): EffortChoice? =
        model?.efforts?.let { efforts -> efforts.firstOrNull { it.level == effort } ?: efforts.firstOrNull { it.id == effort } }
}

/** Which setting a bot card changes. */
enum class BotCardKind { Model, Think }

/** Why a bot card could not do what was asked (shown in the card). */
sealed interface BotCardProblem {
    /** `/model foo`: nothing matched. */
    data class NoMatch(val argument: String) : BotCardProblem

    /** `/model g`: more than one matched. */
    data class Ambiguous(val argument: String) : BotCardProblem

    /** The relay or the computer refused (its message). */
    data class Failed(val message: String) : BotCardProblem
}

/**
 * A local answer to `/model` or `/think` in the transcript (Telegram's bot message with an inline keyboard; not stored
 * on the relay): the choices as buttons until one is applied, then "Model: Grok 4 ✓".
 */
data class BotCard(
    val id: String,
    val kind: BotCardKind,
    val createdAt: Long,
    /** The choice being applied (its button spins), until the command is done. */
    val applying: String? = null,
    /** The applied choice's label: the card is done and its keyboard folds away. */
    val done: String? = null,
    val problem: BotCardProblem? = null,
)
