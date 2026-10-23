package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.ModelChoice
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.RelayException
import dev.chenli.crok.mobile.demo.DemoData
import dev.chenli.crok.mobile.ui.session.ModelState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The model and thinking-level pickers (mobile/DESIGN.md "Model and thinking level"): sections, search and the pills. */
class ModelSetupTest {
    private val models = DemoData.macbookModels

    @Test
    fun aModelsProviderIsItsIdUpToTheFirstSlash() {
        assertEquals("openrouter", ModelSetup.provider("openrouter/qwen/qwen3-coder"))
        assertEquals("deepseek", ModelSetup.provider("deepseek/deepseek-chat"))
        assertNull(ModelSetup.provider("grok-4"))
        assertNull(ModelSetup.provider("/odd"))
    }

    @Test
    fun sectionsFollowTheOrderTheProvidersFirstAppearIn() {
        val sections = ModelSetup.sections(models)
        // The computer's own ids (no provider) first, as the relay sends them in picker order.
        assertEquals(listOf(null, "deepseek", "openrouter"), sections.map { it.provider })
        assertEquals(listOf("grok-code-fast-1", "grok-4", "claude-sonnet-4-5"), sections[0].models.map { it.id })
        assertEquals(models.size, sections.sumOf { it.models.size })
        // A provider that shows up again later joins its first section; a model listed twice shows once.
        val mixed = listOf(ModelChoice("a/1"), ModelChoice("b/1"), ModelChoice("a/2"), ModelChoice("a/1"))
        assertEquals(listOf("a" to listOf("a/1", "a/2"), "b" to listOf("b/1")), ModelSetup.sections(mixed).map { it.provider to it.models.map { m -> m.id } })
    }

    @Test
    fun searchMatchesTheNameIdOrDescriptionIgnoringCase() {
        fun ids(query: String) = ModelSetup.sections(models, query).flatMap { it.models }.map { it.id }
        assertEquals(listOf("openrouter/moonshotai/kimi-k2"), ids("KIMI"))
        // By id: the provider's name finds its models.
        assertEquals(listOf("deepseek/deepseek-chat", "deepseek/deepseek-reasoner"), ids("deepseek/"))
        // By description.
        assertEquals(listOf("claude-sonnet-4-5"), ids("anthropic key"))
        assertEquals(models.map { it.id }, ids("  "))
        // Sections without a match hide; nothing matches: no sections ("No Results").
        assertEquals(listOf("openrouter"), ModelSetup.sections(models, "through openrouter").map { it.provider })
        assertTrue(ModelSetup.sections(models, "gpt").isEmpty())
    }

    @Test
    fun aNewSessionSaysDefaultUntilAModelIsPicked() {
        val row = ModelSetup.row(newSession = true, models = models, model = null, effort = null, available = true)!!
        assertNull(row.model.label)
        // "Default" hides the thinking pill.
        assertNull(row.thinking)

        val grok = ModelSetup.row(true, models, null, null, available = true, picked = SetupChoice("grok-4"))!!
        assertEquals("Grok 4", grok.model.label)
        assertNull(grok.thinking!!.label)
        val level = ModelSetup.row(true, models, null, null, available = true, picked = SetupChoice("grok-4", "xhigh"))!!
        assertEquals("Extra high", level.thinking!!.label)
        // A model without levels: no thinking pill.
        assertNull(ModelSetup.row(true, models, null, null, available = true, picked = SetupChoice("claude-sonnet-4-5"))!!.thinking)
        // No list (an older crok there, or none yet): no row; an offline computer: no row.
        assertNull(ModelSetup.row(true, null, null, null, available = true))
        assertNull(ModelSetup.row(true, models, null, null, available = false))
    }

    @Test
    fun aSessionShowsItsModelAndLevelByName() {
        val row = ModelSetup.row(false, models, "grok-code-fast-1", "medium", available = true)!!
        assertEquals(SetupPill("Grok Code Fast"), row.model)
        assertEquals(SetupPill("Medium"), row.thinking)
        // A model without levels has no thinking pill; one the list does not know shows by its id.
        assertNull(ModelSetup.row(false, models, "claude-sonnet-4-5", null, available = true)!!.thinking)
        val unknown = ModelSetup.row(false, models, "grok-5-preview", "high", available = true)!!
        assertEquals("grok-5-preview", unknown.model.label)
        assertNull(unknown.thinking)
        // A level the session does not report: Default.
        assertNull(ModelSetup.row(false, models, "grok-4", null, available = true)!!.thinking!!.label)
    }

    @Test
    fun theRowHidesOfflineAndWhileStartingAndDimsWithoutAList() {
        assertNull(ModelSetup.row(false, models, "grok-4", "high", available = false))
        assertNull(ModelSetup.row(false, models, "grok-4", "high", available = true, starting = true))
        // An older crok: the session's model, dimmed, still tappable (it says why); without a model name no row.
        val older = ModelSetup.row(false, null, "grok-code-fast-1", null, available = true)!!
        assertEquals(SetupPill("grok-code-fast-1", dimmed = true), older.model)
        assertNull(older.thinking)
        assertNull(ModelSetup.row(false, null, null, null, available = true))
        // The list is on its way: the model as it is, not tappable yet, not dimmed.
        val loading = ModelSetup.row(false, null, "grok-4", "high", available = true, loading = true)!!
        assertEquals(SetupPill("grok-4", enabled = false), loading.model)
    }

    @Test
    fun aChangeOnItsWayShowsTheNewValueBusy() {
        val model = ModelSetup.row(false, models, "grok-code-fast-1", "medium", available = true, changing = SetupChange(model = "grok-4"))!!
        assertEquals(SetupPill("Grok 4", busy = true, enabled = false), model.model)
        // The thinking pill already reads the new model's levels, and waits too.
        assertEquals(SetupPill("Medium", enabled = false), model.thinking)
        val toPlain = ModelSetup.row(false, models, "grok-4", "high", available = true, changing = SetupChange(model = "claude-sonnet-4-5"))!!
        assertNull(toPlain.thinking)

        val effort = ModelSetup.row(false, models, "grok-4", "high", available = true, changing = SetupChange(effort = "xhigh"))!!
        assertEquals(SetupPill("Grok 4", enabled = false), effort.model)
        assertEquals(SetupPill("Extra high", busy = true, enabled = false), effort.thinking)
    }

    @Test
    fun theComputersListWinsAndTheSessionsCopyIsTheFallback() {
        val own = listOf(ModelChoice("grok-4", "Grok 4"))
        // devices:models answered: its list, even a null one (offline, older crok).
        val listed = ModelState.of(own, "grok-code-fast-1", "medium", Result.success(models))
        assertEquals(models, listed.models)
        assertEquals("grok-code-fast-1", listed.current?.id)
        assertFalse(listed.loading)
        assertNull(ModelState.of(own, "grok-4", null, Result.success(null)).models)
        // A relay without devices:models: the session's copy.
        val older = ModelState.of(own, "grok-4", null, Result.failure(RelayException(RelayErrorCode.UNKNOWN, "Could not find public function")))
        assertEquals(own, older.models)
        assertEquals("Grok 4", older.current?.name)
        // Not answered yet: the copy stands in; without one the list is loading.
        assertEquals(own, ModelState.of(own, "grok-4", null, null).models)
        assertTrue(ModelState.of(null, "grok-4", null, null).loading)
    }
}
