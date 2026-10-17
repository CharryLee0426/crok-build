package dev.chenli.crok;

import android.content.ClipData;
import android.os.IBinder;
import android.os.PersistableBundle;
import android.util.Base64;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;

/**
 * Crok's text helper for Android phones: puts text on the clipboard from {@code adb shell}, so
 * the paste key types it in any language, past the keyboard. It runs as the shell user and
 * installs nothing:
 *
 * <pre>CLASSPATH=/data/local/tmp/crok-phone-text.dex app_process / dev.chenli.crok.PhoneText BASE64</pre>
 *
 * where BASE64 is the text's UTF-8. Prints {@code crok-phone-text: ok} once the clipboard holds
 * the text, else {@code crok-phone-text: failed: <why>}. Build with {@code build.sh}.
 */
public final class PhoneText {
    /** The shell user's package: the clipboard checks that the caller's uid owns it. */
    private static final String SHELL_PACKAGE = "com.android.shell";
    /** SystemUI skips its "copied" overlay (Android 13 and later) for a shell clip carrying this. */
    private static final String SUPPRESS_OVERLAY = "com.android.systemui.SUPPRESS_CLIPBOARD_OVERLAY";

    public static void main(String[] args) {
        try {
            String text = new String(Base64.decode(args[0], Base64.DEFAULT), StandardCharsets.UTF_8);
            setClip(text);
            System.out.println("crok-phone-text: ok");
        } catch (Throwable t) {
            Throwable cause = t instanceof InvocationTargetException && t.getCause() != null ? t.getCause() : t;
            System.out.println("crok-phone-text: failed: " + cause);
            System.exit(1);
        }
    }

    private static void setClip(String text) throws Exception {
        ClipData clip = ClipData.newPlainText("crok", text);
        PersistableBundle extras = new PersistableBundle();
        extras.putBoolean(SUPPRESS_OVERLAY, true);
        clip.getDescription().setExtras(extras);

        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class)
                .invoke(null, "clipboard");
        if (binder == null) {
            throw new IllegalStateException("no clipboard service");
        }
        Object clipboard = Class.forName("android.content.IClipboard$Stub")
                .getMethod("asInterface", IBinder.class)
                .invoke(null, binder);

        // IClipboard.setPrimaryClip grew over the years: (clip, package), then a user (10), then
        // an attribution tag and a device. Arguments are filled by type: the first String is the
        // package and later ones null, the first int the user and later ones 0.
        Method set = null;
        for (Method m : Class.forName("android.content.IClipboard").getMethods()) {
            if (m.getName().equals("setPrimaryClip")
                    && (set == null || m.getParameterTypes().length > set.getParameterTypes().length)) {
                set = m;
            }
        }
        if (set == null) {
            throw new NoSuchMethodException("IClipboard.setPrimaryClip");
        }
        Class<?>[] types = set.getParameterTypes();
        Object[] values = new Object[types.length];
        boolean packageGiven = false;
        boolean userGiven = false;
        for (int i = 0; i < types.length; i++) {
            Class<?> type = types[i];
            if (type == ClipData.class) {
                values[i] = clip;
            } else if (type == String.class) {
                values[i] = packageGiven ? null : SHELL_PACKAGE;
                packageGiven = true;
            } else if (type == int.class) {
                values[i] = userGiven ? 0 : currentUser();
                userGiven = true;
            } else if (type == boolean.class) {
                values[i] = false;
            } else if (type == long.class) {
                values[i] = 0L;
            } else {
                values[i] = null;
            }
        }
        set.invoke(clipboard, values);
    }

    /** The user in the foreground, whose apps the paste reaches; 0 when it cannot be read. */
    private static int currentUser() {
        try {
            return (Integer) Class.forName("android.app.ActivityManager")
                    .getMethod("getCurrentUser")
                    .invoke(null);
        } catch (Throwable t) {
            return 0;
        }
    }
}
