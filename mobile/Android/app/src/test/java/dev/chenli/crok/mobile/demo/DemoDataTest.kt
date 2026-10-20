package dev.chenli.crok.mobile.demo

import dev.chenli.crok.mobile.data.EventKind
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class DemoDataTest {
    /** The demo shows the shared Markdown showcase verbatim; the app keeps a copy in its resources. */
    @Test
    fun showcaseIsTheRelaysCopy() {
        val relay = File(System.getProperty("crok.relayDir")!!, "scripts/markdown-showcase.md").readText()
        assertEquals("app/src/main/resources/demo/markdown-showcase.md differs from relay/scripts/markdown-showcase.md", relay, DemoData.markdownShowcase)
        val reply = DemoData.state(0).events.getValue(DemoData.SHOWCASE_SESSION).single { it.kind == EventKind.ASSISTANT }
        assertEquals(relay, reply.text)
    }
}
