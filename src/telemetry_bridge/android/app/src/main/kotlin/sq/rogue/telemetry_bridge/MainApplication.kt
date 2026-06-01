package sq.rogue.telemetry_bridge

import android.content.Context
import io.flutter.app.FlutterApplication
import com.cySdkyc.clx.Helper

class MainApplication : FlutterApplication() {
    override fun attachBaseContext(base: Context?) {
        super.attachBaseContext(base)
        // Crucial Secneo-encrypted class loader initialization for DJI MSDK v5
        Helper.install(this)
    }
}
