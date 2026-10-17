package dev.chenli.crok.mobile.ui.settings

import dev.chenli.crok.mobile.ui.common.GlassScaffold
import dev.chenli.crok.mobile.ui.common.glassBarColors
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.PendingLogin
import dev.chenli.crok.mobile.data.RelayErrorCode
import dev.chenli.crok.mobile.data.relayCode
import dev.chenli.crok.mobile.logic.RelativeTime
import dev.chenli.crok.mobile.logic.UserCode
import dev.chenli.crok.mobile.engine.CrokEngine
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.common.IconBadge
import dev.chenli.crok.mobile.ui.common.InfoLine
import dev.chenli.crok.mobile.ui.common.Section
import dev.chenli.crok.mobile.ui.common.rememberFormatter
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import dev.chenli.crok.mobile.ui.theme.Mono
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

enum class LinkProblem { NotFound, Expired, Used, Denied, NotCrok, ScannerUnavailable, Other }

/** Telegram's QR login, from the phone's side: scan or type the computer's code, see who asks, approve or deny. */
sealed interface LinkStep {
    data class Enter(val problem: LinkProblem? = null, val detail: String? = null) : LinkStep
    data object Checking : LinkStep
    data class Confirm(val login: PendingLogin, val working: Boolean = false) : LinkStep
    data class Approved(val name: String) : LinkStep
    data object Denied : LinkStep
}

class LinkComputerViewModel(private val engine: CrokEngine, initialCode: String?) : ViewModel() {
    private val _code = MutableStateFlow(UserCode.formatTyping(initialCode.orEmpty()))
    val code: StateFlow<String> = _code.asStateFlow()

    private val _step = MutableStateFlow<LinkStep>(LinkStep.Enter())
    val step: StateFlow<LinkStep> = _step.asStateFlow()

    init {
        if (UserCode.normalize(_code.value) != null) lookup()
    }

    fun onCode(text: String) {
        _code.value = UserCode.formatTyping(text)
        if (_step.value is LinkStep.Enter) _step.value = LinkStep.Enter()
    }

    fun onScanned(raw: String) {
        val code = UserCode.fromScan(raw)
        if (code == null) {
            _step.value = LinkStep.Enter(LinkProblem.NotCrok)
            return
        }
        _code.value = code
        lookup()
    }

    fun onScannerUnavailable() {
        _step.value = LinkStep.Enter(LinkProblem.ScannerUnavailable)
    }

    fun lookup() {
        val code = UserCode.normalize(_code.value) ?: return
        _step.value = LinkStep.Checking
        viewModelScope.launch {
            _step.value = try {
                val login = engine.accounts.pendingLogin(code)
                when (login?.status) {
                    null -> LinkStep.Enter(LinkProblem.NotFound)
                    "pending" -> LinkStep.Confirm(login)
                    "expired" -> LinkStep.Enter(LinkProblem.Expired)
                    "denied" -> LinkStep.Enter(LinkProblem.Denied)
                    else -> LinkStep.Enter(LinkProblem.Used)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                problemFor(e)
            }
        }
    }

    fun approve() {
        val confirm = _step.value as? LinkStep.Confirm ?: return
        _step.value = confirm.copy(working = true)
        viewModelScope.launch {
            _step.value = try {
                val approved = engine.accounts.approve(confirm.login.userCode)
                LinkStep.Approved(approved.name.ifBlank { confirm.login.name })
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                problemFor(e)
            }
        }
    }

    fun deny() {
        val confirm = _step.value as? LinkStep.Confirm ?: return
        _step.value = confirm.copy(working = true)
        viewModelScope.launch {
            runCatching { engine.accounts.deny(confirm.login.userCode) }
            _step.value = LinkStep.Denied
        }
    }

    fun startOver() {
        _code.value = ""
        _step.value = LinkStep.Enter()
    }

    private fun problemFor(e: Exception): LinkStep = when (e.relayCode) {
        RelayErrorCode.NOT_FOUND -> LinkStep.Enter(LinkProblem.NotFound)
        RelayErrorCode.EXPIRED -> LinkStep.Enter(LinkProblem.Expired)
        RelayErrorCode.INVALID -> LinkStep.Enter(LinkProblem.Used)
        else -> LinkStep.Enter(LinkProblem.Other, e.message)
    }
}

data class LinkActions(
    val onBack: () -> Unit = {},
    val onCode: (String) -> Unit = {},
    val onScan: () -> Unit = {},
    val onContinue: () -> Unit = {},
    val onApprove: () -> Unit = {},
    val onDeny: () -> Unit = {},
    val onStartOver: () -> Unit = {},
)

@Composable
fun LinkComputerScreen(viewModel: LinkComputerViewModel, onBack: () -> Unit) {
    val code by viewModel.code.collectAsStateWithLifecycle()
    val step by viewModel.step.collectAsStateWithLifecycle()
    val context = LocalContext.current
    LinkComputerContent(
        code = code,
        step = step,
        now = System.currentTimeMillis(),
        actions = LinkActions(
            onBack = onBack,
            onCode = viewModel::onCode,
            onScan = {
                val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
                runCatching {
                    GmsBarcodeScanning.getClient(context, options).startScan()
                        .addOnSuccessListener { barcode -> viewModel.onScanned(barcode.rawValue.orEmpty()) }
                        .addOnFailureListener { viewModel.onScannerUnavailable() }
                }.onFailure { viewModel.onScannerUnavailable() }
            },
            onContinue = viewModel::lookup,
            onApprove = viewModel::approve,
            onDeny = viewModel::deny,
            onStartOver = viewModel::startOver,
        ),
    )
}

@Composable
fun LinkComputerContent(code: String, step: LinkStep, now: Long, actions: LinkActions) {
    val colors = CrokTheme.colors
    GlassScaffold(
        background = colors.grouped,
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = actions.onBack) { Icon(CrokIcons.Back, contentDescription = stringResource(R.string.action_back)) }
                },
                title = { Text(stringResource(R.string.link_title)) },
                colors = glassBarColors(),
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .imePadding()
                .padding(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            when (step) {
                is LinkStep.Enter -> EnterCode(code, step, actions)
                LinkStep.Checking -> {
                    Spacer(Modifier.height(64.dp))
                    CircularProgressIndicator(color = colors.accent)
                    Spacer(Modifier.height(16.dp))
                    Text(stringResource(R.string.link_checking), color = colors.textSecondary)
                }
                is LinkStep.Confirm -> ConfirmLogin(step, now, actions)
                is LinkStep.Approved -> Outcome(CrokIcons.CheckCircle, colors.success, stringResource(R.string.link_approved, step.name), actions)
                LinkStep.Denied -> Outcome(CrokIcons.Close, colors.textSecondary, stringResource(R.string.link_denied), actions)
            }
        }
    }
}

@Composable
private fun EnterCode(code: String, step: LinkStep.Enter, actions: LinkActions) {
    val colors = CrokTheme.colors
    Spacer(Modifier.height(24.dp))
    IconBadge(CrokIcons.QrCode, colors.accent, size = 88.dp)
    Spacer(Modifier.height(20.dp))
    Text(
        stringResource(R.string.link_body),
        color = colors.textSecondary,
        textAlign = TextAlign.Center,
        style = MaterialTheme.typography.bodyLarge,
        modifier = Modifier.padding(horizontal = 32.dp),
    )
    Spacer(Modifier.height(24.dp))
    Button(
        onClick = actions.onScan,
        modifier = Modifier.padding(horizontal = 32.dp).fillMaxWidth().height(50.dp),
        shape = RoundedCornerShape(14.dp),
        colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
    ) {
        Icon(CrokIcons.QrCode, contentDescription = null, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Text(stringResource(R.string.link_scan), fontSize = 16.sp)
    }
    Row(Modifier.padding(horizontal = 32.dp, vertical = 20.dp), verticalAlignment = Alignment.CenterVertically) {
        HorizontalDivider(Modifier.weight(1f), color = colors.divider)
        Text(stringResource(R.string.link_or_enter), color = colors.textTertiary, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 12.dp))
        HorizontalDivider(Modifier.weight(1f), color = colors.divider)
    }
    val complete = UserCode.normalize(code) != null
    OutlinedTextField(
        value = code,
        onValueChange = actions.onCode,
        placeholder = { Text(stringResource(R.string.link_code_hint), fontFamily = Mono, letterSpacing = 3.sp) },
        textStyle = MaterialTheme.typography.titleLarge.copy(fontFamily = Mono, letterSpacing = 3.sp, textAlign = TextAlign.Center),
        singleLine = true,
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, imeAction = ImeAction.Go, autoCorrectEnabled = false),
        keyboardActions = KeyboardActions(onGo = { if (complete) actions.onContinue() }),
        modifier = Modifier.padding(horizontal = 32.dp).fillMaxWidth(),
    )
    step.problem?.let { problem ->
        Spacer(Modifier.height(12.dp))
        Text(
            when (problem) {
                LinkProblem.NotFound -> stringResource(R.string.link_not_found)
                LinkProblem.Expired -> stringResource(R.string.link_expired)
                LinkProblem.Used -> stringResource(R.string.link_used)
                LinkProblem.Denied -> stringResource(R.string.link_denied)
                LinkProblem.NotCrok -> stringResource(R.string.link_not_crok)
                LinkProblem.ScannerUnavailable -> stringResource(R.string.link_scanner_unavailable)
                LinkProblem.Other -> stringResource(R.string.error_generic, step.detail.orEmpty())
            },
            color = colors.danger,
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(horizontal = 32.dp),
        )
    }
    Spacer(Modifier.height(16.dp))
    OutlinedButton(
        onClick = actions.onContinue,
        enabled = complete,
        modifier = Modifier.padding(horizontal = 32.dp).fillMaxWidth().height(48.dp),
        shape = RoundedCornerShape(14.dp),
    ) { Text(stringResource(R.string.link_continue), color = if (complete) colors.accent else colors.textTertiary) }
}

@Composable
private fun ConfirmLogin(step: LinkStep.Confirm, now: Long, actions: LinkActions) {
    val colors = CrokTheme.colors
    val formatter = rememberFormatter()
    val login = step.login
    val isComputer = login.kind == "computer"
    Spacer(Modifier.height(24.dp))
    IconBadge(if (isComputer) CrokIcons.Laptop else CrokIcons.Phone, colors.accent, size = 88.dp)
    Spacer(Modifier.height(16.dp))
    Text(stringResource(R.string.link_confirm_title), style = MaterialTheme.typography.titleLarge, color = colors.textPrimary)
    Spacer(Modifier.height(6.dp))
    Text(login.userCode, fontFamily = Mono, fontSize = 22.sp, letterSpacing = 3.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
    Section {
        InfoLine(stringResource(if (isComputer) R.string.link_kind_computer else R.string.link_kind_phone), login.name)
        if (login.platform.isNotBlank()) InfoLine(stringResource(R.string.devices_platform), login.platform)
        if (login.client.isNotBlank()) InfoLine(stringResource(R.string.devices_app), login.client)
        InfoLine(
            stringResource(R.string.link_requested),
            formatter.ago(RelativeTime.ago(login.createdAt, now, formatter.zone)),
        )
    }
    Row(Modifier.padding(horizontal = 32.dp, vertical = 16.dp), verticalAlignment = Alignment.Top) {
        Icon(CrokIcons.Warning, contentDescription = null, tint = colors.warning, modifier = Modifier.size(18.dp).padding(top = 2.dp))
        Spacer(Modifier.width(8.dp))
        Text(stringResource(R.string.link_confirm_body), color = colors.textSecondary, style = MaterialTheme.typography.bodyMedium)
    }
    Column(Modifier.padding(horizontal = 32.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Button(
            onClick = actions.onApprove,
            enabled = !step.working,
            modifier = Modifier.fillMaxWidth().height(50.dp),
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
        ) {
            if (step.working) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = colors.onAccent)
            } else {
                Text(stringResource(R.string.link_approve), fontSize = 16.sp)
            }
        }
        OutlinedButton(
            onClick = actions.onDeny,
            enabled = !step.working,
            modifier = Modifier.fillMaxWidth().height(50.dp),
            shape = RoundedCornerShape(14.dp),
        ) { Text(stringResource(R.string.link_deny), color = colors.danger, fontSize = 16.sp) }
    }
}

@Composable
private fun Outcome(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: androidx.compose.ui.graphics.Color, text: String, actions: LinkActions) {
    val colors = CrokTheme.colors
    Spacer(Modifier.height(64.dp))
    IconBadge(icon, tint, size = 88.dp)
    Spacer(Modifier.height(20.dp))
    Text(text, color = colors.textPrimary, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(horizontal = 32.dp))
    Spacer(Modifier.height(24.dp))
    Button(
        onClick = actions.onBack,
        modifier = Modifier.padding(horizontal = 32.dp).fillMaxWidth().height(50.dp),
        shape = RoundedCornerShape(14.dp),
        colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
    ) { Text(stringResource(R.string.action_done), fontSize = 16.sp) }
}
