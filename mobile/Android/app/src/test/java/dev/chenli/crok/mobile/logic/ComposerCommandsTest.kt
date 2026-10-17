package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.CommandStatus
import dev.chenli.crok.mobile.data.CommandType
import dev.chenli.crok.mobile.data.EffortChoice
import dev.chenli.crok.mobile.data.EventKind
import dev.chenli.crok.mobile.data.ModelChoice
import dev.chenli.crok.mobile.data.PromptCommand
import dev.chenli.crok.mobile.data.RelayEvent
import dev.chenli.crok.mobile.data.RelayJson
import dev.chenli.crok.mobile.data.SessionDetail
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.data.SlashCommand
import dev.chenli.crok.mobile.demo.DemoData
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The composer's command list, argument matching and bot cards (relay/DESIGN.md §5, "Commands in the composer"). */
class ComposerCommandsTest {
    private val local = ComposerCommands.local(running = true, hasThinking = true).map { CommandEntry(it.command, it) }
    private val session = listOf(
        SlashCommand("compact", "Summarize"),
        SlashCommand("review-pr", "Review a pull request", hint = "<number>"),
        // A session command named like one of the phone's: the phone's wins.
        SlashCommand("model", "The agent's own model picker"),
    )

    @Test
    fun thePhonesCommandsComeFirstAndApplyOnlyWhenTheyCan() {
        assertEquals(listOf("new", "model", "think", "stop", "info"), local.map { it.name })
        assertEquals(listOf("new", "model", "info"), ComposerCommands.local(running = false, hasThinking = false).map { it.command })
        val all = ComposerCommands.suggestions("", menuOpen = true, local, session)!!
        assertEquals(listOf("new", "model", "think", "stop", "info", "compact", "review-pr"), all.map { it.name })
        assertEquals(LocalCommand.Model, all.first { it.name == "model" }.local)
    }

    @Test
    fun slashOpensTheListAndTypingFiltersIt() {
        assertNull(ComposerCommands.suggestions("", menuOpen = false, local, session))
        assertEquals(listOf("model"), ComposerCommands.suggestions("/mo", menuOpen = false, local, session)!!.map { it.name })
        assertEquals(listOf("review-pr"), ComposerCommands.suggestions("/RE", menuOpen = false, local, session)!!.map { it.name })
        // Once arguments start, the list goes.
        assertNull(ComposerCommands.suggestions("/model grok", menuOpen = true, local, session))
        // Text that is not a command never shows it, Menu or not.
        assertNull(ComposerCommands.suggestions("hello", menuOpen = true, local, session))
    }

    @Test
    fun commandsWithArgumentsFillTheField() {
        val all = ComposerCommands.suggestions("/", menuOpen = false, local, session)!!.associateBy { it.name }
        assertTrue(all.getValue("new").takesArguments)
        assertTrue(all.getValue("model").takesArguments)
        assertTrue(all.getValue("think").takesArguments)
        assertTrue(all.getValue("review-pr").takesArguments)
        assertFalse(all.getValue("stop").takesArguments)
        assertFalse(all.getValue("compact").takesArguments)
    }

    @Test
    fun parsesCommandsAndTheirArguments() {
        assertEquals(ParsedCommand("new", "fix the flaky test", LocalCommand.New), ComposerCommands.parse("/new fix the flaky test"))
        assertEquals(ParsedCommand("Model", null, LocalCommand.Model), ComposerCommands.parse("  /Model  "))
        assertEquals(ParsedCommand("review-pr", "42", null), ComposerCommands.parse("/review-pr 42"))
        assertNull(ComposerCommands.parse("not a command"))
        assertNull(ComposerCommands.parse("/"))
    }

    private val models = DemoData.macbookModels

    @Test
    fun modelsMatchByIdOrNameExactFirstThenAUniquePrefix() {
        assertEquals("grok-4", (ComposerCommands.matchModel("GROK 4", models) as ChoiceMatch.One).choice.id)
        assertEquals("grok-4", (ComposerCommands.matchModel("grok-4", models) as ChoiceMatch.One).choice.id)
        assertEquals("claude-sonnet-4-5", (ComposerCommands.matchModel("claude", models) as ChoiceMatch.One).choice.id)
        assertEquals(ChoiceMatch.Ambiguous, ComposerCommands.matchModel("grok", models))
        assertEquals(ChoiceMatch.None, ComposerCommands.matchModel("gpt", models))
    }

    @Test
    fun thinkingLevelsMatchByIdLevelOrName() {
        val efforts = listOf(
            EffortChoice("effort-lo", "Low", value = "low"),
            EffortChoice("effort-hi", "High", value = "high"),
            EffortChoice("effort-xhi", "Extra high", value = "xhigh"),
        )
        assertEquals("effort-hi", (ComposerCommands.matchEffort("high", efforts) as ChoiceMatch.One).choice.id)
        assertEquals("effort-xhi", (ComposerCommands.matchEffort("xh", efforts) as ChoiceMatch.One).choice.id)
        assertEquals("effort-xhi", (ComposerCommands.matchEffort("extra", efforts) as ChoiceMatch.One).choice.id)
        assertEquals("effort-lo", (ComposerCommands.matchEffort("EFFORT-LO", efforts) as ChoiceMatch.One).choice.id)
        assertEquals(ChoiceMatch.None, ComposerCommands.matchEffort("max", efforts))
    }

    @Test
    fun theCurrentThinkingLevelIsTheOneWhoseLevelIsTheSessionsEffort() {
        val model = ModelChoice("m", "M", efforts = listOf(EffortChoice("e1", "Low", value = "low"), EffortChoice("e2", "High", value = "high")))
        assertEquals("e2", ComposerCommands.currentEffort(model, "high")?.id)
        // Older relays: no value, the id is the level.
        val old = ModelChoice("m", "M", efforts = listOf(EffortChoice("low", "Low"), EffortChoice("high", "High")))
        assertEquals("high", ComposerCommands.currentEffort(old, "high")?.id)
        assertNull(ComposerCommands.currentEffort(null, "high"))
    }

    @Test
    fun botCardsSitAmongTheEventsByTime() {
        val events = listOf(
            RelayEvent("e1", 1, "k1", EventKind.USER, "hi", origin = "local", at = 1_000),
            RelayEvent("e2", 2, "k2", EventKind.ASSISTANT, "hello", at = 3_000),
        )
        val card = BotCard("c1", BotCardKind.Model, createdAt = 2_000)
        val items = Transcript.build(events, emptyList(), emptyList(), sessionRunning = false, historyComplete = true, zone = ZoneOffset.UTC, cards = listOf(card))
        // Newest first: the reply, the card, the prompt, the day.
        assertEquals(listOf("e:e2", "b:c1", "e:e1"), items.filterNot { it is TranscriptItem.Day }.map { it.key })
    }

    @Test
    fun aCreateCommandShowsLikeAPromptWithTicks() {
        val create = PromptCommand("cmd-1", "client-1", "Start the release", CommandStatus.PENDING, null, "Pixel 9", mine = true, createdAt = 5_000, updatedAt = 5_000, type = CommandType.CREATE)
        val items = Transcript.build(emptyList(), listOf(create), emptyList(), sessionRunning = false, historyComplete = true, zone = ZoneOffset.UTC)
        val user = items.filterIsInstance<TranscriptItem.User>().single()
        assertEquals("Start the release", user.text)
        assertEquals(Tick.Clock, user.tick)
    }

    @Test
    fun newFieldsDecodeAndOldRelaysStillWork() {
        val detail = RelayJson.decodeFromString(
            SessionDetail.serializer(),
            """{"_id":"s1","model":"grok-4","effort":"high","starting":true,
               "models":[{"id":"grok-4","name":"Grok 4","efforts":[{"id":"hi","name":"High","value":"high"}],"defaultEffort":"hi"}]}""",
        )
        assertTrue(detail.starting)
        assertEquals("Grok 4", detail.currentModel?.name)
        assertEquals("high", detail.models!!.single().efforts.single().level)
        val old = RelayJson.decodeFromString(SessionDetail.serializer(), """{"_id":"s1","starting":null,"models":null}""")
        assertFalse(old.starting)
        assertNull(old.models)
        val row = RelayJson.decodeFromString(SessionRow.serializer(), """{"_id":"r1"}""")
        assertFalse(row.starting)
        val prompt = RelayJson.decodeFromString(PromptCommand.serializer(), """{"_id":"c1","text":"hi"}""")
        assertEquals(CommandType.PROMPT, prompt.type)
    }
}
