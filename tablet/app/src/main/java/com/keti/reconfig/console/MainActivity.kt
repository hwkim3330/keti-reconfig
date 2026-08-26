package com.keti.reconfig.console

import android.annotation.SuppressLint
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.view.WindowManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.EditText
import android.widget.FrameLayout
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity

/**
 * KETI Reconfig Console — a native shell around the keti-reconfig unified web
 * console (/manage on the sender Pi). One tablet app that drives everything the
 * 3 Pis do: flood START/STOP + presets, CBS / TAS / FRER / QoS on the two D10
 * switches, and the video-receiver state — all proxied through the Pi so the
 * tablet only needs to reach one host over Wi-Fi.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var web: WebView
    private val prefs by lazy { getSharedPreferences("console", MODE_PRIVATE) }

    private fun url() = "http://${prefs.getString("pi_ip", DEFAULT_IP)}:$PORT/manage"

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        immersive()

        val root = FrameLayout(this)
        web = WebView(this)
        root.addView(web)
        setContentView(root)

        with(web.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            useWideViewPort = true
            loadWithOverviewMode = true
            cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
        }
        web.webChromeClient = WebChromeClient()
        web.webViewClient = object : WebViewClient() {
            override fun onReceivedError(v: WebView, req: WebResourceRequest, err: WebResourceError) {
                if (req.isForMainFrame) showConfig(true)   // can't reach the Pi -> let user fix the IP
            }
        }
        // Long-press an empty area to change the Pi address.
        web.setOnLongClickListener { showConfig(false); true }

        if (prefs.getString("pi_ip", null) == null) showConfig(false) else web.loadUrl(url())
    }

    private fun showConfig(afterError: Boolean) {
        val input = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT
            setText(prefs.getString("pi_ip", DEFAULT_IP))
            hint = "sender Pi IP (e.g. 192.168.77.11)"
        }
        AlertDialog.Builder(this)
            .setTitle(if (afterError) "Can't reach the Pi — set its IP" else "Sender Pi IP")
            .setMessage("Address of the Pi running the console (:$PORT/manage).")
            .setView(input)
            .setPositiveButton("Connect") { _, _ ->
                prefs.edit().putString("pi_ip", input.text.toString().trim()).apply()
                web.loadUrl(url())
            }
            .setNegativeButton("Retry") { _, _ -> web.loadUrl(url()) }
            .setCancelable(!afterError)
            .show()
    }

    private fun immersive() {
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN)
    }

    override fun onResume() { super.onResume(); immersive() }

    override fun onBackPressed() {
        if (web.canGoBack()) web.goBack() else super.onBackPressed()
    }

    companion object {
        const val DEFAULT_IP = "192.168.77.11"   // sender Pi (Pi1) on the demo net
        const val PORT = 8080
    }
}
