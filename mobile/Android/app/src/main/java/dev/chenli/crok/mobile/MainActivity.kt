package dev.chenli.crok.mobile

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.viewModels
import androidx.browser.auth.AuthTabIntent
import androidx.browser.customtabs.CustomTabsClient
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.net.toUri
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dev.chenli.crok.mobile.auth.AuthEffect
import dev.chenli.crok.mobile.ui.CrokRoot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val appViewModel: AppViewModel by viewModels {
        AppViewModel.factory((application as CrokApplication).graph)
    }

    /** Must be registered before the activity starts; the result arrives whenever the Auth Tab closes. */
    private lateinit var authTab: ActivityResultLauncher<Intent>

    /** The sign-in page could not be opened in any browser: the Waiting screen says where to go instead. */
    private val browserMissing = MutableStateFlow<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        authTab = AuthTabIntent.registerActivityResultLauncher(this) { appViewModel.pollNow() }
        handleIntent(intent)
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                appViewModel.effects.collect { effect ->
                    when (effect) {
                        is AuthEffect.OpenBrowser -> openSignInPage(effect.url)
                    }
                }
            }
        }
        setContent { CrokRoot(appViewModel, browserMissing) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        intent ?: return
        val data = intent.data
        if (data?.scheme == "crok" && data.host == "signed-in") appViewModel.pollNow()
        if (BuildConfig.DEMO_ALLOWED && isDemoRequest(intent)) appViewModel.enterDemo()
    }

    private fun isDemoRequest(intent: Intent): Boolean {
        if (!intent.hasExtra(EXTRA_DEMO)) return false
        if (intent.getBooleanExtra(EXTRA_DEMO, false)) return true
        val text = intent.getStringExtra(EXTRA_DEMO) ?: return false
        return text.equals("true", ignoreCase = true) || text == "1"
    }

    /** Auth Tab when the browser supports it, else a Custom Tab, else any browser. */
    private fun openSignInPage(url: String) {
        val uri: Uri = url.toUri()
        browserMissing.value = null
        try {
            val provider = CustomTabsClient.getPackageName(this, null)
            when {
                provider != null && CustomTabsClient.isAuthTabSupported(this, provider) ->
                    AuthTabIntent.Builder().build().launch(authTab, uri, "crok")
                provider != null -> CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(this, uri)
                else -> startActivity(Intent(Intent.ACTION_VIEW, uri))
            }
        } catch (_: ActivityNotFoundException) {
            browserMissing.value = url.substringBefore("/link")
        }
    }

    companion object {
        /** `adb shell am start -n dev.chenli.crok.mobile/.MainActivity --ez crokDemo true` (debug builds). */
        const val EXTRA_DEMO = "crokDemo"
    }
}
