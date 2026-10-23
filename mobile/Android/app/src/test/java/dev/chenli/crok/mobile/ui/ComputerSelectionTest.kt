package dev.chenli.crok.mobile.ui

import dev.chenli.crok.mobile.data.ComputerSelectionStore
import dev.chenli.crok.mobile.data.Device
import dev.chenli.crok.mobile.data.MemoryKeyValueStore
import dev.chenli.crok.mobile.data.SessionGroup
import dev.chenli.crok.mobile.data.SessionRow
import dev.chenli.crok.mobile.logic.Computers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The default computer is pinned once the relay has answered, so the Sessions tab never jumps on its own. */
class ComputerSelectionTest {
    private val store = ComputerSelectionStore(MemoryKeyValueStore())

    private fun device(id: String, createdAt: Long) = Device(id = id, kind = "computer", name = id, createdAt = createdAt, online = true)

    /** One project per computer, its session last active at the given time. */
    private fun groups(vararg activity: Pair<String, Long>) = activity.map { (deviceId, at) ->
        SessionGroup(
            key = "$deviceId:/code",
            deviceId = deviceId,
            deviceName = deviceId,
            deviceOnline = true,
            path = "/code",
            name = "code",
            lastActivityAt = at,
            sessions = listOf(SessionRow(id = "s-$deviceId", deviceId = deviceId, deviceName = deviceId, lastActivityAt = at)),
        )
    }

    private fun settle(groups: List<SessionGroup>, devices: List<Device>?, live: Boolean = true) =
        settleSelectedComputer(store, Computers.list(devices, groups), live, devicesLoaded = devices != null)

    @Test
    fun theDefaultIsPinnedOnceAndThenStays() {
        val devices = listOf(device("mac", 1), device("studio", 2))
        // The cache alone, or the session list without the device list, pins nothing yet.
        settle(groups("mac" to 10, "studio" to 50), devices, live = false)
        assertNull(store.selected.value)
        settle(groups("mac" to 10, "studio" to 50), devices = null)
        assertNull(store.selected.value)
        // Both answered: the most recently active computer is remembered.
        settle(groups("mac" to 10, "studio" to 50), devices)
        assertEquals("studio", store.selected.value)
        // Later the other computer becomes the most recently active: the selection does not move.
        settle(groups("mac" to 90, "studio" to 50), devices)
        assertEquals("studio", store.selected.value)
        assertEquals("studio", ComputerState.build(groups("mac" to 90, "studio" to 50), true, devices, store.selected.value).selectedId)
    }

    @Test
    fun aRememberedComputerThatIsGoneIsPinnedAgain() {
        store.select("studio")
        val afterRevoke = listOf(device("mac", 1), device("linux", 3))
        settle(groups("mac" to 10, "linux" to 70), afterRevoke)
        assertEquals("linux", store.selected.value)
        // A remembered computer that is still there is kept, whatever is most recent.
        settle(groups("mac" to 99, "linux" to 70), afterRevoke)
        assertEquals("linux", store.selected.value)
    }
}
