package dev.chenli.crok.mobile.ui.o11y

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.chenli.crok.mobile.data.O11yPage
import dev.chenli.crok.mobile.data.O11yPageState
import dev.chenli.crok.mobile.data.O11yRangeStore
import dev.chenli.crok.mobile.engine.ConnectionState
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.engine.delayedForDisplay
import dev.chenli.crok.mobile.logic.O11yRefreshPolicy
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.scan
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** One o11y screen: what the relay holds for the page, and whether a newer one is on its way. */
data class O11yUi(
    /** Null until the relay first answered. */
    val state: O11yPageState? = null,
    /** The subscription failed before any answer (a relay without `o11y:page`, the network). */
    val error: String? = null,
    /** The relay does not know `o11y:page` at all. */
    val missing: Boolean = false,
    /** This phone asked for a newer page and is waiting for the answer. */
    val asking: Boolean = false,
    val connection: ConnectionState = ConnectionState.Connected,
    val now: Long = 0,
) {
    val page: O11yPage? get() = state?.page

    /** The relay is building a newer page (or this phone asked for one). */
    val refreshing: Boolean get() = asking || state?.refreshing == true
}

private data class Answer(val state: O11yPageState? = null, val error: String? = null, val missing: Boolean = false)

/**
 * One page: its cached copy at once, a newer one asked for when it is stale (mobile/DESIGN.md "Loading and refresh",
 * O11yPageModel on iOS). Everything runs only while the screen collects [state].
 */
@OptIn(ExperimentalCoroutinesApi::class)
class O11yPageViewModel(
    private val engine: CrokEngine,
    val pageId: String,
    private val lang: String,
    private val ranges: O11yRangeStore,
) : ViewModel() {
    /** The range picked on this phone; null until one is (the relay then uses the page's default). */
    private val range = MutableStateFlow(ranges.get(pageId))
    private val asking = MutableStateFlow(false)
    private val _pulling = MutableStateFlow(false)

    /** Pull to refresh is waiting for the relay. */
    val pulling: StateFlow<Boolean> = _pulling.asStateFlow()

    private var latest: O11yPageState? = null
    private var lastAsk: Long? = null

    private val answers: Flow<Answer> = range
        .flatMapLatest { picked -> engine.o11y.page(pageId, picked, lang) }
        .scan(Answer()) { before, result ->
            result.fold(
                onSuccess = { Answer(it) },
                onFailure = { error ->
                    val text = error.message ?: error.javaClass.simpleName
                    before.copy(error = text, missing = text.contains("Could not find"))
                },
            )
        }
        .onEach { answer ->
            answer.state?.let {
                latest = it
                askIfStale()
            }
        }

    /** The clock for "Updated 2 min ago", and the 60-second look at whether the page went stale. */
    private val ticker: Flow<Long> = flow {
        var tick = 0
        while (true) {
            emit(engine.clock())
            // The label every 30 s, the stale check every 60 s (the first answer already checked).
            if (tick++ % 2 == 1) askIfStale()
            delay(O11yRefreshPolicy.CHECK_EVERY_MS / 2)
        }
    }

    val state: StateFlow<O11yUi> = combine(answers, asking, engine.connection.delayedForDisplay(), ticker) { answer, waiting, connection, now ->
        O11yUi(answer.state, answer.error, answer.missing, waiting, connection, now)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), O11yUi(now = engine.clock()))

    /** The range the page shows: what the relay built, else what this phone picked. */
    val currentRange: String? get() = latest?.page?.range ?: range.value

    fun select(picked: String) {
        if (picked == currentRange) return
        ranges.set(pageId, picked)
        range.value = picked
        lastAsk = null
    }

    /** Asks for a newer page when the one held is missing or older than 90 s, at most every 15 s. */
    fun askIfStale() {
        val held = latest ?: return
        val now = engine.clock()
        if (!O11yRefreshPolicy.isStale(held, now) || held.refreshing || asking.value) return
        lastAsk?.let { if (now - it < O11yRefreshPolicy.MINIMUM_GAP_MS) return }
        viewModelScope.launch { ask(force = false) }
    }

    /** Pull to refresh: the spinner stays until the relay has answered. */
    fun pullToRefresh() {
        if (_pulling.value) return
        _pulling.value = true
        viewModelScope.launch {
            try {
                ask(force = true)
            } finally {
                _pulling.value = false
            }
        }
    }

    private suspend fun ask(force: Boolean) {
        val held = latest
        if (held != null && held.state != O11yPageState.State.OK) return
        asking.value = true
        lastAsk = engine.clock()
        try {
            engine.o11y.refresh(pageId, range.value, lang, force)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // The page says why (its error, or the connection title); nothing to add here.
        } finally {
            asking.value = false
        }
    }
}
