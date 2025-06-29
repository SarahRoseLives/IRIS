package com.example.iris

import android.os.Bundle
import android.util.Log
import com.google.android.gms.common.GooglePlayServicesNotAvailableException
import com.google.android.gms.common.GooglePlayServicesRepairableException
import com.google.android.gms.security.ProviderInstaller
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        installModernTlsProvider()
    }

    private fun installModernTlsProvider() {
        try {
            // Attempt to install the modern security provider.
            ProviderInstaller.installIfNeeded(applicationContext)
            Log.d("MainActivity", "Modern TLS provider installed successfully.")
        } catch (e: GooglePlayServicesRepairableException) {
            // The user can likely fix this by updating Google Play Services.
            Log.e("MainActivity", "Google Play Services is repairable: ${e.message}")
        } catch (e: GooglePlayServicesNotAvailableException) {
            // This is a more serious error, the device may not be supported.
            Log.e("MainActivity", "Google Play Services not available: ${e.message}")
        } catch (e: Exception) {
            Log.e("MainActivity", "An unexpected error occurred while installing the TLS provider: ${e.message}")
        }
    }
}